package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

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
	exit  *int32
	cause string // "" when the Exec reached End; else one of the failure causes above
	msg   string
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
func execOne(ctx context.Context, client pb.SandboxExecClient, sandboxID string, reqID uint64, cmd string, timeoutS uint32, key string) execResult {
	callCtx, cancel := context.WithTimeout(ctx, time.Duration(timeoutS+callDeadlineSlackS)*time.Second)
	defer cancel()
	stream, err := client.Exec(callCtx, &pb.ExecRequest{
		SandboxId: sandboxID,
		Exec: &pb.Exec{
			ReqId:        reqID,
			Command:      cmd,
			TimeoutS:     timeoutS,
			WorkspaceKey: key,
		},
	})
	if err != nil {
		return execResult{cause: rpcCause(err), msg: err.Error()}
	}
	var res execResult
	sawErr := false
	for {
		ev, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return execResult{exit: res.exit, cause: rpcCause(err), msg: err.Error()}
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
		if strings.Contains(strings.ToLower(res.msg), "no live worker") {
			res.cause = causeNoLiveWorker
		}
	case res.exit == nil:
		res.cause, res.msg = causeRPCError, "stream ended without End or error"
	}
	return res
}
