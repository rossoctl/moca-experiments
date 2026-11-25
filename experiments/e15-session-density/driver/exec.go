package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

// dialReady returns a connection that is already READY.
//
// Copied from moca remote-worker/cmd/exec-driver/drive.go at v0.9.0 (c13d5564), with one change:
// extra dial options may be passed (tests dial an in-process bufconn); with none, the connection
// is plaintext as in exec-driver. The rationale is exec-driver's: bringing the connection up
// BEFORE any session starts means the first Exec of the run pays no more than the last one does.
func dialReady(ctx context.Context, target string, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	if len(opts) == 0 {
		opts = []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	}
	cc, err := grpc.NewClient(target, opts...)
	if err != nil {
		return nil, fmt.Errorf("creating a client for %s: %w", target, err)
	}
	cc.Connect()
	for {
		s := cc.GetState()
		if s == connectivity.Ready {
			return cc, nil
		}
		if !cc.WaitForStateChange(ctx, s) {
			_ = cc.Close()
			return nil, fmt.Errorf("connection to %s never reached READY (last state %s): refusing to time Execs over a connection that is not up, because every one of them would record a client-side error as a latency: %w", target, s, ctx.Err())
		}
	}
}

// Causes recorded in calls.jsonl.
const (
	causeOK           = "ok"
	causeExitMismatch = "exit_mismatch"
	causeNoLiveWorker = "no_live_worker"
	causeUnavailable  = "unavailable"
	causeExecError    = "exec_error"
	causeDeadline     = "deadline"
	causeCutAtEnd     = "cut_at_end" // cancelled at the grace deadline before its planned completion; not a failure
	causeRPCError     = "rpc_error"
)

// execResult is one Exec's outcome. exit is nil when no End arrived.
type execResult struct {
	exit   *int32
	cause  string // "" when the Exec reached End; else one of the failure causes above
	msg    string
	stderr []byte // the last stderrTailMax bytes of the Exec's stderr (the joined script's marker)
	// events are the LeaseEvents the stream carried, in order, kept on every outcome: a notice is
	// acknowledged once it is queued on the stream, so a failed call may have consumed one.
	events []leaseEvent
	// stdout is the first stdoutMax bytes of the Exec's stdout, kept only when execOne is asked to
	// (--record-stdout); stdoutCut is set when more arrived.
	stdout    []byte
	stdoutCut bool
	// refused names a refusal that came before the command ran (refusalOf); "" otherwise.
	refused string
}

// refusalOf names a refusal that comes BEFORE the command starts, as moca's sbx client classes them
// (remote-worker/cmd/sbx/sbx.go refusalClass) plus #644's host backstop: the worker's vmpool refusals
// (errors.go RefusalError, "<reason>: <detail>"), sent as an ExecError or as the status's message, the
// session's full queue, and the relay's per-sandbox in-flight cap. It also names the refusals of the
// mode or of the call itself (PR #34, E17B-R41a), which run nothing either: the worker's stale mode
// epoch and lease-unsupported (vmpool spells them "stale-mode:"/"lease-unsupported:", exec/runner.go
// and session/lease.go "lease_unsupported:"), the relay's PERMISSION_DENIED ("exec not permitted",
// sandbox-caller.ts) and its req_id_in_flight (ALREADY_EXISTS). "" for every other failure: it may
// have run part of the command. The lease driver judges not_lease only on a call that ran (E17B-R30).
func refusalOf(code codes.Code, msg string) string {
	for _, r := range []string{"memory-budget", "host-memory", "max-runs", "stale-mode", "lease-unsupported"} {
		if strings.HasPrefix(msg, r+":") {
			return r
		}
	}
	for _, r := range []string{"stale_mode", "lease_unsupported"} {
		if strings.HasPrefix(msg, r+":") {
			return strings.ReplaceAll(r, "_", "-")
		}
	}
	switch {
	case strings.HasPrefix(msg, "busy: queue full"):
		return "queue-full"
	case code == codes.ResourceExhausted && strings.HasPrefix(msg, "sandbox busy"):
		// Only the relay's "sandbox busy": grpc's own message-size limits are RESOURCE_EXHAUSTED too.
		return "relay-busy"
	case code == codes.PermissionDenied:
		return "permission-denied"
	case code == codes.AlreadyExists && strings.Contains(msg, "already in flight"):
		return "req-id-in-flight"
	}
	return ""
}

// configRefusal reports whether a refusalOf class is a CONFIGURATION refusal (E17B-R42): the mode, the token's
// binding or the request itself is wrong, so every later call of the session will be refused the same way. The
// others (memory-budget, host-memory, max-runs, queue-full, relay-busy) are load outcomes.
func configRefusal(class string) bool {
	switch class {
	case "stale-mode", "lease-unsupported", "permission-denied", "req-id-in-flight":
		return true
	}
	return false
}

// statusRefusal is refusalOf for a gRPC error.
func statusRefusal(err error) string {
	st, _ := status.FromError(err)
	return refusalOf(st.Code(), st.Message())
}

// stdoutMax bounds the stdout --record-stdout keeps per call (E17B-R22).
const stdoutMax = 1024

// keepHead appends b to head up to max bytes; it reports whether any of b was dropped.
func keepHead(head, b []byte, max int) ([]byte, bool) {
	if room := max - len(head); len(b) > room {
		return append(head, b[:room]...), true
	}
	return append(head, b...), false
}

// cutRunes drops a trailing incomplete UTF-8 sequence that a byte bound split (at most 3 bytes).
func cutRunes(b []byte) []byte {
	for k := 0; k < utf8.UTFMax && len(b) > 0; k++ {
		if r, size := utf8.DecodeLastRune(b); r != utf8.RuneError || size != 1 {
			return b
		}
		b = b[:len(b)-1]
	}
	return b
}

// stderrTailMax bounds the stderr kept per Exec: enough for the failure marker after any noise.
const stderrTailMax = 4 << 10

// appendTail appends b to tail and keeps only the last stderrTailMax bytes.
func appendTail(tail, b []byte) []byte {
	if len(b) >= stderrTailMax {
		return append(tail[:0], b[len(b)-stderrTailMax:]...)
	}
	tail = append(tail, b...)
	if over := len(tail) - stderrTailMax; over > 0 {
		tail = append(tail[:0], tail[over:]...)
	}
	return tail
}

// rpcCause classifies a gRPC error returned by Exec or by the stream.
func rpcCause(err error) string {
	st, _ := status.FromError(err)
	switch {
	case strings.Contains(strings.ToLower(st.Message()), "no live worker"):
		return causeNoLiveWorker
	case st.Code() == codes.DeadlineExceeded || errors.Is(err, context.DeadlineExceeded):
		return causeDeadline
	case st.Code() == codes.Unavailable:
		return causeUnavailable
	default:
		return causeRPCError
	}
}

// callDeadlineSlackS bounds one Exec client-side, past the worker's own timeout_s, so a lost End
// cannot hang a session forever.
const callDeadlineSlackS = 30

// execOne issues one Exec and drains its stream to io.EOF (as exec-driver's oneExec does, so the
// measured time is not shortened by stopping at End). An in-stream ExecEvent.error is a failed
// Exec even though the relay follows it with an OK status. ctx must carry the bearer metadata.
// keepStdout keeps the first stdoutMax bytes of stdout (--record-stdout); otherwise stdout is
// drained and dropped, as it always was.
func execOne(ctx context.Context, client pb.SandboxExecClient, sandboxID string, reqID uint64, cmd string, timeoutS uint32, key string, keepStdout bool) execResult {
	return execReq(ctx, client, sandboxID, &pb.Exec{ReqId: reqID, Command: cmd, TimeoutS: timeoutS, WorkspaceKey: key}, keepStdout)
}

// execReq is execOne for any Exec (E17d: the process kinds, l2.go), bounded by its own timeout_s plus the slack.
func execReq(ctx context.Context, client pb.SandboxExecClient, sandboxID string, ex *pb.Exec, keepStdout bool) execResult {
	callCtx, cancel := context.WithTimeout(ctx, time.Duration(ex.GetTimeoutS()+callDeadlineSlackS)*time.Second)
	defer cancel()
	stream, err := client.Exec(callCtx, &pb.ExecRequest{SandboxId: sandboxID, Exec: ex})
	if err != nil {
		return execResult{cause: rpcCause(err), msg: err.Error(), refused: statusRefusal(err)}
	}
	var res execResult
	sawErr := false
	for {
		ev, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return execResult{exit: res.exit, cause: rpcCause(err), msg: err.Error(), stderr: res.stderr, events: res.events, stdout: res.stdout, stdoutCut: res.stdoutCut, refused: statusRefusal(err)}
		}
		if l := ev.GetLease(); l != nil {
			res.events = append(res.events, eventOf(l))
		}
		if ch := ev.GetChunk(); ch != nil && ch.GetStream() == pb.Stream_STREAM_STDERR {
			res.stderr = appendTail(res.stderr, ch.GetData())
		} else if ch != nil && keepStdout && ch.GetStream() == pb.Stream_STREAM_STDOUT {
			var cut bool
			if res.stdout == nil {
				res.stdout = []byte{}
			}
			res.stdout, cut = keepHead(res.stdout, ch.GetData(), stdoutMax)
			res.stdoutCut = res.stdoutCut || cut
		}
		if e := ev.GetError(); e != nil && !sawErr {
			sawErr = true
			res.msg = e.GetMessage()
		}
		if end := ev.GetEnd(); end != nil && res.exit == nil {
			code := end.GetExitCode()
			res.exit = &code
		}
	}
	switch {
	case sawErr:
		res.cause = causeExecError
		res.refused = refusalOf(codes.OK, res.msg)
		if strings.Contains(strings.ToLower(res.msg), "no live worker") {
			res.cause = causeNoLiveWorker
		}
	case res.exit == nil:
		res.cause, res.msg = causeRPCError, "stream ended without End or error"
	}
	return res
}
