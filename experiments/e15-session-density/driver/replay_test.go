package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const testToken = "tok"

// fakeExec is one Exec the fake server saw.
type fakeExec struct {
	key, cmd   string
	recv, done time.Time
}

// fake is an in-process SandboxExecServer. A call's Exec is a JoinPlan script; the fake walks its
// steps and picks each step's behaviour by the step's command text: "hold:<ms>" holds then exits 0;
// "exit1" exits 1; "inerr" sends an in-stream ExecError and returns OK (what the relay does);
// "nolive" returns the relay's Unavailable refusal; "unavail" a plain Unavailable; anything else
// exits 0; "kill9" is killed by SIGKILL (137); "spew" writes 10 KiB of stderr. A step whose exit
// differs from the script's expected one writes the script's E15_FAILED_STEP marker to stderr and
// ends the Exec with the step code, as bash would; a trailing "sleep S" is held. Every hold ends early when the
// client cancels. A command that is not a joined script (the end-session marker) runs as one step.
type fake struct {
	pb.UnimplementedSandboxExecServer
	mu      sync.Mutex
	execs   []fakeExec
	failEnd bool // answer the end-session Exec with exit 1
}

var (
	stepRE = regexp.MustCompile(`(?s)\(\n(.*?)\n\); __rc=\$\?; \[ "\$__rc" -eq (\d+) \] \|\| \{ echo "E15_FAILED_STEP=\d+ RC=\$__rc" >&2; exit (\d+); \}\n`)
	loopRE = regexp.MustCompile(`(?s)^for __i in \$\(seq (\d+)\); do \(\n(.*?)\n\); __rc=\$\?; \[ "\$__rc" -eq (\d+) \] \|\| \{ __k=\$\(\((\d+) \+ __i - 1\)\); [^\n]*; \}; done\n`)
	tailRE = regexp.MustCompile(`\nsleep ([0-9.]+)\nexit 0\n$`)
	scanRE = regexp.MustCompile(`(?s)^\(\n(.*?)\n\); __rc=\$\?; \[ "\$__rc" -eq 0 \] \|\| \{ echo "E15_FAILED_STEP=scan RC=\$__rc" >&2; exit 89; \}\n`)
)

func (f *fake) Exec(req *pb.ExecRequest, stream grpc.ServerStreamingServer[pb.ExecEvent]) error {
	recv := time.Now()
	md, _ := metadata.FromIncomingContext(stream.Context())
	if a := md.Get("authorization"); len(a) != 1 || a[0] != "Bearer "+testToken {
		return status.Error(codes.Unauthenticated, "bad bearer")
	}
	e := req.GetExec()
	minT, maxT := uint32(120), ^uint32(0)
	if e.GetCommand() == EndSessionCommand {
		minT, maxT = 60, 60
	}
	if req.GetSandboxId() != "e15" || e.GetWorkspaceKey() == "" || e.GetTimeoutS() < minT || e.GetTimeoutS() > maxT {
		return status.Error(codes.InvalidArgument, "bad request")
	}
	// The relay decodes req_id into a JS number and refuses one above 2^53-1 with
	// "Internal: Error deserializing request" (k8s-sandbox gen longToNumber).
	if e.GetReqId() > 1<<53-1 {
		return status.Error(codes.Internal, "Error deserializing request")
	}
	defer func() {
		f.mu.Lock()
		f.execs = append(f.execs, fakeExec{e.GetWorkspaceKey(), e.GetCommand(), recv, time.Now()})
		f.mu.Unlock()
	}()
	end := func(code int32) error {
		return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_End{End: &pb.End{ReqId: e.GetReqId(), ExitCode: code}}})
	}
	hold := func(d time.Duration) {
		select {
		case <-stream.Context().Done():
		case <-time.After(d):
		}
	}
	script := e.GetCommand()
	type fstep struct {
		cmd        string
		want, code int32
	}
	var steps []fstep
	rest0 := script
	scanned := false
	if m := scanRE.FindStringSubmatch(script); m != nil {
		steps = append(steps, fstep{m[1], 0, 89})
		rest0 = script[len(m[0]):]
		scanned = true
	}
	for rest := rest0; ; {
		if m := stepRE.FindStringSubmatchIndex(rest); m != nil && m[0] == 0 {
			w, _ := strconv.Atoi(rest[m[4]:m[5]])
			c, _ := strconv.Atoi(rest[m[6]:m[7]])
			steps = append(steps, fstep{rest[m[2]:m[3]], int32(w), int32(c)})
			rest = rest[m[1]:]
		} else if m := loopRE.FindStringSubmatch(rest); m != nil {
			n, _ := strconv.Atoi(m[1])
			w, _ := strconv.Atoi(m[3])
			k0, _ := strconv.Atoi(m[4])
			for i := 0; i < n; i++ {
				steps = append(steps, fstep{m[2], int32(w), int32(min(stepExitBase+k0+i, maxStepExit))})
			}
			rest = rest[len(m[0]):]
		} else {
			break
		}
	}
	if steps == nil {
		steps = []fstep{{script, -1, 0}} // not joined: its own exit is the Exec's
	}
	stderr := func(b []byte) error {
		return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Chunk{Chunk: &pb.Chunk{ReqId: e.GetReqId(), Stream: pb.Stream_STREAM_STDERR, Data: b}}})
	}
	for k, st := range steps {
		var rc int32
		switch cmd := st.cmd; {
		case strings.HasPrefix(cmd, "hold:"):
			ms, _ := strconv.Atoi(strings.TrimPrefix(cmd, "hold:"))
			hold(time.Duration(ms) * time.Millisecond)
		case cmd == "exit1":
			rc = 1
		case cmd == "inerr":
			return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Error{Error: &pb.ExecError{ReqId: e.GetReqId(), Message: "boom"}}})
		case cmd == "nolive":
			return status.Error(codes.Unavailable, "no live worker for sandbox 'e15'")
		case cmd == EndSessionCommand && f.failEnd:
			rc = 1
		case cmd == "unavail":
			return status.Error(codes.Unavailable, "connection reset by peer")
		case cmd == "kill9":
			rc = 137
		case cmd == "spew":
			if err := stderr(bytes.Repeat([]byte("x"), 10<<10)); err != nil {
				return err
			}
		}
		if st.want < 0 {
			return end(rc)
		}
		if rc != st.want {
			mark := strconv.Itoa(k)
			if scanned {
				mark = strconv.Itoa(k - 1)
				if k == 0 {
					mark = "scan"
				}
			}
			if err := stderr(fmt.Appendf(nil, "E15_FAILED_STEP=%s RC=%d\n", mark, rc)); err != nil {
				return err
			}
			return end(st.code)
		}
	}
	if m := tailRE.FindStringSubmatch(script); m != nil {
		sec, _ := strconv.ParseFloat(m[1], 64)
		hold(time.Duration(sec * float64(time.Second)))
	}
	return end(0)
}

func (f *fake) byKey() map[string][]fakeExec {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string][]fakeExec{}
	for _, e := range f.execs {
		out[e.key] = append(out[e.key], e)
	}
	for _, v := range out {
		sort.Slice(v, func(a, b int) bool { return v[a].recv.Before(v[b].recv) })
	}
	return out
}

func newFake(t *testing.T) (pb.SandboxExecClient, *fake) {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	f := &fake{}
	srv := grpc.NewServer()
	pb.RegisterSandboxExecServer(srv, f)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cc, err := dialReady(ctx, "passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cc.Close() })
	return pb.NewSandboxExecClient(cc), f
}

// testLib maps each class to one invocation whose command is the class name itself (so the
// fake's behaviour is picked by class), nominal 1 ms: Plan yields exactly one Exec per call.
func testLib(exits map[string]int32, classes ...string) *Library {
	l := &Library{Classes: map[string][]Invocation{}}
	for _, c := range classes {
		l.Classes[c] = []Invocation{{ID: c, Cmd: c, Exit: exits[c], NominalMs: 1}}
	}
	l.Standin.InterpreterClass = classes[0]
	return l
}

// sess builds a session whose calls use classes in turn, each offset offsetMs from the previous.
func sess(id, user string, offsetMs int64, classes ...string) Session {
	s := Session{ID: id, User: user, Provider: "claude"}
	for i, c := range classes {
		s.Calls = append(s.Calls, Call{I: i, Class: c, DurMs: 10, WorkMs: 1, GapMs: 5, OffsetMs: offsetMs})
	}
	return s
}

type result struct {
	calls    []callRecord
	sessions []sessionRecord
	cpu      []cpuRecord
	cpuRaw   []map[string]any
	err      error
}

func readLines[T any](t *testing.T, b *bytes.Buffer) []T {
	t.Helper()
	var out []T
	sc := bufio.NewScanner(b)
	for sc.Scan() {
		var v T
		if err := json.Unmarshal(sc.Bytes(), &v); err != nil {
			t.Fatalf("%v: %s", err, sc.Text())
		}
		out = append(out, v)
	}
	return out
}

func baseCfg() Config {
	return Config{N: 1, Seed: 7, UserCap: 1, Window: time.Second, Spread: 0, Grace: 5 * time.Second, SandboxID: "e15", RunID: "t", Token: testToken}
}

func newReplay(t *testing.T, cfg Config, ss []Session, lib *Library, client pb.SandboxExecClient) (*Replayer, func() result) {
	t.Helper()
	var cb, sb, pb_, raw bytes.Buffer
	rec := NewRecorder(&cb, &sb, &pb_)
	r, err := NewReplayer(cfg, ss, lib, client, rec)
	if err != nil {
		t.Fatal(err)
	}
	return r, func() result {
		err := r.Run(context.Background())
		if ferr := rec.Flush(); ferr != nil {
			t.Fatal(ferr)
		}
		raw.Write(pb_.Bytes())
		return result{readLines[callRecord](t, &cb), readLines[sessionRecord](t, &sb), readLines[cpuRecord](t, &pb_), readLines[map[string]any](t, &raw), err}
	}
}

func run(t *testing.T, cfg Config, ss []Session, lib *Library, client pb.SandboxExecClient) result {
	t.Helper()
	_, do := newReplay(t, cfg, ss, lib, client)
	return do()
}

func TestClosedLoopWaitsForResult(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window = 700 * time.Millisecond
	res := run(t, cfg, []Session{sess("s", "u", 50, "hold:200", "hold:200", "hold:200")}, testLib(nil, "hold:200"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	ex := f.byKey()["e15-t-0-0"]
	if len(ex) != 3 {
		t.Fatalf("first session sent %d execs, want 3", len(ex))
	}
	for i := 1; i < len(ex); i++ {
		if ex[i].recv.Before(ex[i-1].done) {
			t.Fatalf("exec %d sent before exec %d ended: open loop", i, i-1)
		}
	}
	var first *sessionRecord
	for i := range res.sessions {
		if res.sessions[i].Session == "e15-t-0-0" {
			first = &res.sessions[i]
		}
	}
	if first == nil || first.WindowCalls != 3 || first.ObservedMs < 600 {
		t.Fatalf("session record %+v, want 3 calls observed >= 600 ms", first)
	}
	if first.PlannedMs != 3*10+2*5 {
		t.Fatalf("planned_ms %d, want 40 (durs + gaps but the last)", first.PlannedMs)
	}
	for _, c := range res.calls {
		if c.Status != "ok" || c.ObservedMs < 200 || c.PlannedDurMs != 10 || c.PlannedGapMs != 5 || c.Trace != "s" || c.Provider != "claude" || c.Execs != 1 {
			t.Fatalf("call %+v", c)
		}
	}
}

func TestPopulationHeldAtN(t *testing.T) {
	client, _ := newFake(t)
	var ss []Session
	for u := 0; u < 4; u++ {
		for k := 0; k < 2; k++ {
			ss = append(ss, sess(fmt.Sprintf("s%d%d", u, k), fmt.Sprintf("u%d", u), 20, "hold:10", "hold:10", "hold:10"))
		}
	}
	cfg := baseCfg()
	cfg.N, cfg.UserCap, cfg.Spread, cfg.Window = 4, 0.25, 100*time.Millisecond, time.Second
	r, do := newReplay(t, cfg, ss, testLib(nil, "hold:10"), client)
	done := make(chan result)
	go func() { done <- do() }()
	time.Sleep(150 * time.Millisecond)
	samples := 0
	for deadline := time.Now().Add(700 * time.Millisecond); time.Now().Before(deadline); time.Sleep(2 * time.Millisecond) {
		if got := r.Live(); got != 4 {
			t.Fatalf("live sessions %d after start-up, want 4", got)
		}
		samples++
	}
	res := <-done
	if res.err != nil {
		t.Fatal(res.err)
	}
	seen := map[string]bool{}
	for _, c := range res.calls {
		seen[c.Session] = true
	}
	if len(seen) < 8 || samples < 50 {
		t.Fatalf("%d session instances, %d samples: sessions were not replaced", len(seen), samples)
	}
}

func TestStartupSpread(t *testing.T) {
	client, f := newFake(t)
	var ss []Session
	for u := 0; u < 10; u++ {
		ss = append(ss, sess(fmt.Sprintf("s%d", u), fmt.Sprintf("u%d", u), 5000, "q", "q", "q"))
	}
	cfg := baseCfg()
	cfg.N, cfg.UserCap, cfg.Spread, cfg.Window = 10, 0.1, time.Second, 1300*time.Millisecond
	res := run(t, cfg, ss, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	var lo, hi time.Time
	n := 0
	for k, ex := range f.byKey() {
		if !strings.HasSuffix(k, "-0") {
			continue
		}
		n++
		if lo.IsZero() || ex[0].recv.Before(lo) {
			lo = ex[0].recv
		}
		if ex[0].recv.After(hi) {
			hi = ex[0].recv
		}
	}
	if span := hi.Sub(lo); n != 10 || span < 900*time.Millisecond || span > 1200*time.Millisecond {
		t.Fatalf("%d first calls spanning %v, want 10 spanning >= 0.9 s of a 1 s spread", n, span)
	}
}

func TestInStreamErrorIsFailure(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 100 * time.Millisecond
	res := run(t, cfg, []Session{sess("s", "u", 20, "inerr", "inerr", "inerr")}, testLib(nil, "inerr"), client)
	if res.err != nil || len(res.calls) == 0 {
		t.Fatal(res.err, len(res.calls))
	}
	for _, c := range res.calls {
		if c.Status != "err" || c.Cause != "exec_error" {
			t.Fatalf("in-stream error recorded as %s/%s", c.Status, c.Cause)
		}
	}
}

func TestExitMismatchIsFailure(t *testing.T) {
	for _, tc := range []struct {
		expect        int32
		status, cause string
	}{{0, "err", "exit_mismatch"}, {1, "ok", "ok"}} {
		client, _ := newFake(t)
		cfg := baseCfg()
		cfg.Window = 100 * time.Millisecond
		res := run(t, cfg, []Session{sess("s", "u", 20, "exit1", "exit1", "exit1")}, testLib(map[string]int32{"exit1": tc.expect}, "exit1"), client)
		if res.err != nil || len(res.calls) == 0 {
			t.Fatal(res.err, len(res.calls))
		}
		c := res.calls[0]
		// The joined Exec expects 0; a mismatched step k ends it with 90+k.
		wantExit, wantStep := int32(90), 0
		if tc.status == "ok" {
			wantExit = 0
		}
		if c.Status != tc.status || c.Cause != tc.cause || c.Exit == nil || *c.Exit != wantExit || c.ExpectedExit != 0 || c.Execs != 1 {
			t.Fatalf("expect %d: got %+v", tc.expect, c)
		}
		if (tc.status == "err") != (c.FailedStep != nil) || (c.FailedStep != nil && *c.FailedStep != stepID(wantStep)) {
			t.Fatalf("expect %d: failed_step %v, want step %d on a mismatch only", tc.expect, c.FailedStep, wantStep)
		}
	}
}

func TestNoLiveWorkerIsRecordedNotFatal(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 300 * time.Millisecond
	res := run(t, cfg, []Session{sess("s", "u", 20, "nolive", "nolive", "nolive")}, testLib(nil, "nolive"), client)
	if res.err != nil {
		t.Fatalf("driver stopped on a per-call error: %v", res.err)
	}
	if len(res.calls) < 6 {
		t.Fatalf("%d calls recorded: the driver did not keep running past refusals", len(res.calls))
	}
	for _, c := range res.calls {
		if c.Status != "err" || c.Cause != "no_live_worker" || c.Exit != nil {
			t.Fatalf("got %+v", c)
		}
	}
}

func TestWindowFlag(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Warmup, cfg.Window = 300*time.Millisecond, 300*time.Millisecond
	classes := make([]string, 30)
	for i := range classes {
		classes[i] = "q"
	}
	res := run(t, cfg, []Session{sess("s", "u", 50, classes...)}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	in, out := 0, 0
	for _, c := range res.calls {
		want := c.TMs >= 300 && c.TMs < 600
		if c.InWindow != want || c.TMs >= 600 {
			t.Fatalf("call at t=%.1f ms in_window=%v", c.TMs, c.InWindow)
		}
		if c.InWindow {
			in++
		} else {
			out++
		}
	}
	if in == 0 || out == 0 {
		t.Fatalf("in=%d out=%d: want both warm-up and window calls", in, out)
	}
	sum := 0
	for _, s := range res.sessions {
		if s.WindowCalls == 0 {
			t.Fatalf("session %s recorded with no window calls", s.Session)
		}
		sum += s.WindowCalls
	}
	if sum != in {
		t.Fatalf("sessions.jsonl counts %d window calls, calls.jsonl %d", sum, in)
	}
}

func TestNoNegativeSleep(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	s := Session{ID: "s", User: "u", Calls: []Call{
		{I: 0, Class: "hold:300", DurMs: 10, WorkMs: 1, OffsetMs: 0},
		{I: 1, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 250},
		{I: 2, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 200},
	}}
	cfg.Window = 600 * time.Millisecond
	res := run(t, cfg, []Session{s}, testLib(nil, "hold:300", "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	ex := f.byKey()["e15-t-0-0"]
	if len(ex) != 3 {
		t.Fatalf("%d execs", len(ex))
	}
	if d := ex[1].recv.Sub(ex[0].done); d > 50*time.Millisecond {
		t.Fatalf("call 1 (offset 250 ms < 300 ms observed) waited %v after call 0 ended: want immediate", d)
	}
	if d := ex[2].recv.Sub(ex[1].recv); d < 190*time.Millisecond || d > 260*time.Millisecond {
		t.Fatalf("call 2 sent %v after call 1, want its 200 ms offset", d)
	}
}

func TestCapUnsatisfiableAborts(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.N, cfg.UserCap = 2, 0.15
	res := run(t, cfg, []Session{sess("a", "u", 20, "q", "q", "q"), sess("b", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if !errors.Is(res.err, ErrCapUnsatisfiable) {
		t.Fatalf("got %v, want ErrCapUnsatisfiable", res.err)
	}
}

func TestDriverCPUSampled(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 1100 * time.Millisecond
	res := run(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil || len(res.cpu) < 3 || res.cpu[len(res.cpu)-1].UtimeMs+res.cpu[len(res.cpu)-1].StimeMs <= 0 {
		t.Fatalf("%v %+v", res.err, res.cpu)
	}
	h := res.cpuRaw[0]
	if h["header"] != true || h["num_cpu"].(float64) < 1 || h["goos"] == "" {
		t.Fatalf("first driver-cpu line %v, want the header with num_cpu and goos", h)
	}
	if e, ok := h["t0_epoch"].(float64); !ok || e < 1e9 {
		t.Fatalf("header %v lacks t0_epoch", h)
	}
	for _, r := range res.cpuRaw[1:] {
		if _, ok := r["header"]; ok {
			t.Fatalf("header repeated: %v", r)
		}
	}
}

func TestParseProcStat(t *testing.T) {
	line := "4242 (e15 drv) S 1 4242 4242 0 -1 4194560 100 0 0 0 250 37 0 0 20 0 9 0 100 1 1 1"
	u, s, err := parseProcStat(line)
	if err != nil || u != 2500 || s != 370 {
		t.Fatalf("%d %d %v", u, s, err)
	}
}

func TestMainRefusesEmptyToken(t *testing.T) {
	var stderr bytes.Buffer
	code := realMain([]string{"--corpus", "x", "--library", "y", "--n", "1", "--run-id", "r", "--out", t.TempDir()},
		func(string) string { return "" }, &stderr)
	if code == 0 || !strings.Contains(stderr.String(), "MOCA_RELAY_EXEC_TOKEN") {
		t.Fatalf("code %d: %s", code, stderr.String())
	}
}

// firstSession returns the sessions.jsonl record for key.
func firstSession(t *testing.T, res result, key string) sessionRecord {
	t.Helper()
	for _, s := range res.sessions {
		if s.Session == key {
			return s
		}
	}
	t.Fatalf("no session record for %s in %+v", key, res.sessions)
	return sessionRecord{}
}

func TestChainLastInWindowPaceAgrees(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 1500 * time.Millisecond
	s := Session{ID: "s", User: "u", Provider: "codex", Calls: []Call{
		{I: 0, Class: "q", DurMs: 10, WorkMs: 1, GapMs: 5},
		{I: 1, Class: "q", DurMs: 10, WorkMs: 1, GapMs: 5, OffsetMs: 15},
		{I: 2, Class: "hold:50", DurMs: 400, WorkMs: 1, GapMs: 5, OffsetMs: 15, Chain: true},
	}}
	res := run(t, cfg, []Session{s}, testLib(nil, "q", "hold:50"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	var chain *callRecord
	for i := range res.calls {
		c := &res.calls[i]
		if c.Session != "e15-t-0-0" {
			continue
		}
		if c.Call == 2 {
			chain = c
		}
		if c.TailMs != 0 || c.Execs != 1 {
			t.Fatalf("call %+v, want tail_ms 0 and one Exec", c)
		}
	}
	// The 399 ms idle tail runs inside the chain's Exec, so observed spans it.
	if chain == nil || chain.Status != "ok" || chain.ObservedMs < 50+390 {
		t.Fatalf("chain call %+v, want ok and observed >= the 50 ms hold + 0.4 s tail", chain)
	}
	sr := firstSession(t, res, "e15-t-0-0")
	if sr.WindowCalls != 3 || sr.PlannedMs != 10+5+10+5+400 {
		t.Fatalf("session %+v, want 3 calls and planned_ms 430 (the tail is in the last call's End)", sr)
	}
	if d := sr.ObservedMs - float64(sr.PlannedMs); d < 0 || d > 50+40 {
		t.Fatalf("observed %.1f vs planned %d: differ by %.1f ms, want within the 50 ms hold (+slack)", sr.ObservedMs, sr.PlannedMs, d)
	}
}

func TestChainTailInsideExec(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window = 800 * time.Millisecond
	s := Session{ID: "s", User: "u", Calls: []Call{
		{I: 0, Class: "q", DurMs: 300, WorkMs: 1, Chain: true},
		{I: 1, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 10},
		{I: 2, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 10},
	}}
	res := run(t, cfg, []Session{s}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	ex := f.byKey()["e15-t-0-0"]
	if len(ex) != 3 {
		t.Fatalf("%d execs", len(ex))
	}
	// The 299 ms tail is the chain Exec's final sleep (0.3 s): the sandbox is held for the
	// chain's lifetime, and the driver does not sleep it again before the next call.
	if d := ex[0].done.Sub(ex[0].recv); d < 290*time.Millisecond || !strings.HasSuffix(ex[0].cmd, "\nsleep 0.299\nexit 0\n") {
		t.Fatalf("chain Exec lasted %v (script %q), want its 0.299 s tail inside it", d, ex[0].cmd)
	}
	if d := ex[1].recv.Sub(ex[0].done); d > 60*time.Millisecond {
		t.Fatalf("call 1 sent %v after the chain Exec ended, want at once (its offset is long past)", d)
	}
	if d := ex[2].recv.Sub(ex[1].recv); d > 60*time.Millisecond {
		t.Fatalf("call 2 waited %v, want its 10 ms offset", d)
	}
}

func TestChainTailCutAtEnd(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window, cfg.Grace = 200*time.Millisecond, 100*time.Millisecond
	s := Session{ID: "s", User: "u", Calls: []Call{
		{I: 0, Class: "q", DurMs: 60000, WorkMs: 1, Chain: true},
		{I: 1, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 10},
		{I: 2, Class: "q", DurMs: 10, WorkMs: 1, OffsetMs: 10},
	}}
	t0 := time.Now()
	res := run(t, cfg, []Session{s}, testLib(nil, "q"), client)
	if el := time.Since(t0); res.err != nil || el > time.Second {
		t.Fatalf("%v after %v: the 60 s tail was not cut at the grace deadline", res.err, el)
	}
	// Planned to complete 60 s after its send, long after the grace end: cut, not a failure.
	if len(res.calls) != 1 || res.calls[0].Status != "err" || res.calls[0].Cause != "cut_at_end" ||
		res.calls[0].TailMs != 0 || res.calls[0].Execs != 1 || !res.calls[0].InWindow || res.calls[0].Exit != nil {
		t.Fatalf("calls %+v, want the one chain call recorded err/cut_at_end, execs 1, tail_ms 0", res.calls)
	}
	// A cut call never completed: it is not pace (SPEC §8 condition 3), so the session has no
	// completed window call and no sessions.jsonl line.
	for _, sr := range res.sessions {
		if sr.Session == "e15-t-0-0" {
			t.Fatalf("session %+v counts the cut call", sr)
		}
	}
}

func TestGraceDeadlineCancelsInFlight(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window, cfg.Grace = 100*time.Millisecond, 100*time.Millisecond
	// Two steps per call (fill picks the 50 ms invocation twice for 100 ms of work), joined into
	// one Exec that holds 300 ms. Planned to complete at send+100 ms, before the grace end.
	lib := &Library{Classes: map[string][]Invocation{"hold:150": {{ID: "h", Cmd: "hold:150", NominalMs: 50}}}}
	lib.Standin.InterpreterClass = "hold:150"
	s := Session{ID: "s", User: "u", Calls: []Call{
		{I: 0, Class: "hold:150", DurMs: 100, WorkMs: 100},
		{I: 1, Class: "hold:150", DurMs: 100, WorkMs: 100},
		{I: 2, Class: "hold:150", DurMs: 100, WorkMs: 100},
	}}
	t0 := time.Now()
	res := run(t, cfg, []Session{s}, lib, client)
	el := time.Since(t0)
	if res.err != nil || el > 400*time.Millisecond {
		t.Fatalf("%v after %v: want the run to stop at end+grace (200 ms)", res.err, el)
	}
	if len(res.calls) != 1 {
		t.Fatalf("calls %+v", res.calls)
	}
	c := res.calls[0]
	if c.Status != "err" || c.Cause != "deadline" || c.Execs != 1 || c.Exit != nil {
		t.Fatalf("call %+v, want its one Exec cancelled at the grace deadline as cause deadline", c)
	}
}

func TestUnavailableIsNotNoLiveWorker(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 100 * time.Millisecond
	res := run(t, cfg, []Session{sess("s", "u", 20, "unavail", "unavail", "unavail")}, testLib(nil, "unavail"), client)
	if res.err != nil || len(res.calls) == 0 {
		t.Fatal(res.err, len(res.calls))
	}
	for _, c := range res.calls {
		if c.Status != "err" || c.Cause != "unavailable" {
			t.Fatalf("got %s/%s, want err/unavailable", c.Status, c.Cause)
		}
	}
}

func TestPlanErrorFailsBeforeRun(t *testing.T) {
	client, f := newFake(t)
	ss := []Session{sess("ok", "u", 20, "q", "q", "q"), sess("bad", "v", 20, "q", "q", "nosuchclass")}
	var b bytes.Buffer
	_, err := NewReplayer(baseCfg(), ss, testLib(nil, "q"), client, NewRecorder(&b, &b, &b))
	if err == nil || !strings.Contains(err.Error(), "bad call 2") {
		t.Fatalf("got %v, want a plan error naming bad call 2 before the run", err)
	}
	if len(f.byKey()) != 0 {
		t.Fatal("execs were sent")
	}
}

// endSessionRun replays one slot of 3-call sessions (10 ms offsets) for 250 ms, so several sessions
// finish mid-run and one is live at the end.
func endSessionRun(t *testing.T, on, failEnd bool) (result, *fake) {
	t.Helper()
	client, f := newFake(t)
	f.failEnd = failEnd
	cfg := baseCfg()
	cfg.Window, cfg.EndSessionExec = 250*time.Millisecond, on
	return run(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q", "q", "q")}, testLib(nil, "q"), client), f
}

func TestEndSessionExecPerSession(t *testing.T) {
	res, f := endSessionRun(t, true, false)
	if res.err != nil {
		t.Fatal(res.err)
	}
	keys := map[string]bool{}
	for _, c := range res.calls {
		if c.Class == EndSessionCommand || strings.Contains(c.Msg, "e15-end-session") {
			t.Fatalf("end-session Exec recorded as a call: %+v", c)
		}
		keys[c.Session] = true
	}
	if len(keys) < 3 {
		t.Fatalf("only %d sessions ran; want several finishing mid-run", len(keys))
	}
	by := f.byKey()
	for k := range keys {
		ex := by[k]
		n := 0
		for i, e := range ex {
			if e.cmd == EndSessionCommand {
				n++
				if i != len(ex)-1 {
					t.Fatalf("%s: end-session Exec was not the session's last Exec", k)
				}
			}
		}
		if n != 1 {
			t.Fatalf("%s got %d end-session Execs, want 1 (including the session live at the end)", k, n)
		}
	}
	// Each mid-run end is sent before the slot's next session starts.
	for seq := 1; ; seq++ {
		next, ok := by[fmt.Sprintf("e15-t-0-%d", seq)]
		if !ok {
			break
		}
		prev := by[fmt.Sprintf("e15-t-0-%d", seq-1)]
		if end := prev[len(prev)-1]; next[0].recv.Before(end.done) {
			t.Fatalf("session %d started before session %d's end-session Exec finished", seq, seq-1)
		}
	}
	last := res.cpuRaw[len(res.cpuRaw)-1]
	if last["footer"] != true || int(last["end_sessions_sent"].(float64)) != len(keys) ||
		int(last["end_sessions_ok"].(float64)) != len(keys) || last["end_sessions_failed"].(float64) != 0 {
		t.Fatalf("footer %v, want sent=ok=%d failed=0", last, len(keys))
	}
}

func TestEndSessionExecFailuresCounted(t *testing.T) {
	res, _ := endSessionRun(t, true, true)
	if res.err != nil {
		t.Fatal(res.err)
	}
	last := res.cpuRaw[len(res.cpuRaw)-1]
	sent := last["end_sessions_sent"].(float64)
	if last["footer"] != true || sent < 3 || last["end_sessions_failed"].(float64) != sent || last["end_sessions_ok"].(float64) != 0 {
		t.Fatalf("footer %v, want every end-session counted failed", last)
	}
	for _, c := range res.calls {
		if c.Status != "ok" {
			t.Fatalf("a failed end-session Exec leaked into calls.jsonl: %+v", c)
		}
	}
}

func TestEndSessionExecOffByDefault(t *testing.T) {
	res, f := endSessionRun(t, false, false)
	if res.err != nil {
		t.Fatal(res.err)
	}
	for k, ex := range f.byKey() {
		for _, e := range ex {
			if e.cmd == EndSessionCommand {
				t.Fatalf("%s: end-session Exec sent with the flag off", k)
			}
		}
	}
	for _, r := range res.cpuRaw {
		if _, ok := r["footer"]; ok {
			t.Fatalf("footer written with the flag off: %v", r)
		}
	}
}

func TestEndSessionExecAfterGraceDeadline(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window, cfg.Grace, cfg.EndSessionExec = 100*time.Millisecond, 0, true
	res := run(t, cfg, []Session{sess("s", "u", 1000, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	ex := f.byKey()["e15-t-0-0"]
	if len(ex) != 2 || ex[1].cmd != EndSessionCommand {
		t.Fatalf("execs %+v, want the call then the end-session Exec after the grace deadline", ex)
	}
	if last := res.cpuRaw[len(res.cpuRaw)-1]; last["end_sessions_ok"].(float64) != 1 {
		t.Fatalf("footer %v", last)
	}
}

func TestOneExecPerRecordedCall(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window = 400 * time.Millisecond
	// fill picks the 60 ms invocation 5 times for 300 ms of work: five steps, one Exec.
	lib := &Library{Classes: map[string][]Invocation{"q": {{ID: "q", Cmd: "q", NominalMs: 60}}}}
	lib.Standin.InterpreterClass = "q"
	s := Session{ID: "s", User: "u", Calls: []Call{
		{I: 0, Class: "q", DurMs: 300, WorkMs: 300},
		{I: 1, Class: "q", DurMs: 300, WorkMs: 300, OffsetMs: 20},
		{I: 2, Class: "q", DurMs: 400, WorkMs: 300, OffsetMs: 20, Chain: true},
	}}
	res := run(t, cfg, []Session{s}, lib, client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	ex := f.byKey()["e15-t-0-0"]
	var mine []callRecord
	for _, c := range res.calls {
		if c.Session == "e15-t-0-0" {
			mine = append(mine, c)
		}
	}
	if len(ex) != len(mine) || len(ex) != 3 {
		t.Fatalf("%d Execs for %d recorded calls, want one each (3)", len(ex), len(mine))
	}
	for i, e := range ex {
		if !strings.HasPrefix(e.cmd, "for __i in $(seq 5); do") || strings.Count(e.cmd, "__rc=$?") != 1 {
			t.Fatalf("Exec %d does not join its 5 identical steps into one loop:\n%s", i, e.cmd)
		}
	}
	for _, c := range res.calls {
		if c.Execs != 1 || c.TailMs != 0 || c.Status != "ok" || c.ExpectedExit != 0 || c.FailedStep != nil {
			t.Fatalf("call %+v, want execs 1, tail_ms 0, ok", c)
		}
	}
}

func TestFailedStepRecorded(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 100 * time.Millisecond
	// fill for 160 ms: "q" (100 ms), then 60 ms remain -> "exit1" (60 ms). Both expect 0; the
	// fake's exit1 exits 1, so step 1 fails and the joined Exec ends 91.
	lib := &Library{Classes: map[string][]Invocation{"mix": {
		{ID: "q", Cmd: "q", NominalMs: 100}, {ID: "x", Cmd: "exit1", NominalMs: 60}}}}
	lib.Standin.InterpreterClass = "mix"
	var calls []Call
	for i := 0; i < 3; i++ {
		calls = append(calls, Call{I: i, Class: "mix", DurMs: 160, WorkMs: 160, OffsetMs: 20})
	}
	res := run(t, cfg, []Session{{ID: "s", User: "u", Calls: calls}}, lib, client)
	if res.err != nil || len(res.calls) == 0 {
		t.Fatal(res.err, len(res.calls))
	}
	c := res.calls[0]
	if c.Status != "err" || c.Cause != "exit_mismatch" || c.Exit == nil || *c.Exit != 91 || c.ExpectedExit != 0 || c.FailedStep == nil || *c.FailedStep != 1 {
		t.Fatalf("call %+v (failed_step %v), want exit_mismatch, exit 91, failed_step 1", c, c.FailedStep)
	}
	if !strings.Contains(c.Msg, "step 1") || !strings.Contains(c.Msg, "exit1") {
		t.Fatalf("msg %q does not name the failing step", c.Msg)
	}
}

func TestGraceCutAtEndVsDeadline(t *testing.T) {
	for _, tc := range []struct {
		durMs int64
		cause string
	}{{150, "deadline"}, {5000, "cut_at_end"}} {
		client, _ := newFake(t)
		cfg := baseCfg()
		cfg.Window, cfg.Grace = 100*time.Millisecond, 200*time.Millisecond
		// One 1 s hold per call: in flight at the grace end (300 ms) either way. Planned to
		// complete at send+150 ms (before the grace end) or send+5 s (after it).
		lib := testLib(nil, "hold:1000")
		s := Session{ID: "s", User: "u", Calls: []Call{
			{I: 0, Class: "hold:1000", DurMs: tc.durMs, WorkMs: 1},
			{I: 1, Class: "hold:1000", DurMs: tc.durMs, WorkMs: 1},
			{I: 2, Class: "hold:1000", DurMs: tc.durMs, WorkMs: 1},
		}}
		res := run(t, cfg, []Session{s}, lib, client)
		if res.err != nil || len(res.calls) != 1 {
			t.Fatalf("dur %d: %v %+v", tc.durMs, res.err, res.calls)
		}
		if c := res.calls[0]; c.Status != "err" || c.Cause != tc.cause || c.Execs != 1 {
			t.Fatalf("dur %d: call %+v, want err/%s", tc.durMs, c, tc.cause)
		}
	}
}

// callWithPlan sends one hand-built plan through runCall (Plan's fill cannot place a chosen
// command at step 40) and returns the record.
func callWithPlan(t *testing.T, plan []Planned) callRecord {
	t.Helper()
	client, _ := newFake(t)
	r, _ := newReplay(t, baseCfg(), []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	r.t0 = time.Now()
	r.warmEnd, r.end, r.graceEnd = r.t0, r.t0.Add(time.Minute), r.t0.Add(2*time.Minute)
	ctx := metadata.AppendToOutgoingContext(context.Background(), "authorization", "Bearer "+testToken)
	rec, _ := r.runCall(ctx, "e15-t-0-0", Session{ID: "s"}, Call{I: 0, Class: "k", DurMs: 10}, plan, time.Now())
	return rec
}

func TestFailedStepPastTheCap(t *testing.T) {
	plan := make([]Planned, 45)
	for i := range plan {
		plan[i] = Planned{Cmd: "spew"} // 10 KiB of stderr each: the marker must survive in the tail
	}
	plan[40] = Planned{Cmd: "exit1"}
	c := callWithPlan(t, plan)
	if c.Cause != "exit_mismatch" || c.Exit == nil || *c.Exit != maxStepExit || c.FailedStep == nil || *c.FailedStep != 40 ||
		c.FailedRC == nil || *c.FailedRC != 1 {
		t.Fatalf("call %+v (failed_step %v failed_rc %v), want exit 125, failed_step 40, failed_rc 1", c, c.FailedStep, c.FailedRC)
	}
	if !strings.Contains(c.Msg, "step 40") || !strings.Contains(c.Msg, ": exit1") {
		t.Fatalf("msg %q does not name step 40's command", c.Msg)
	}
}

func TestFailedStepSignal(t *testing.T) {
	c := callWithPlan(t, []Planned{{Cmd: "q"}, {Cmd: "kill9"}})
	if c.Cause != "exit_mismatch" || c.FailedStep == nil || *c.FailedStep != 1 || c.FailedRC == nil || *c.FailedRC != 137 {
		t.Fatalf("call %+v (failed_step %v failed_rc %v), want step 1 killed: failed_rc 137", c, c.FailedStep, c.FailedRC)
	}
}

func TestFailedStepFallbackWithoutMarker(t *testing.T) {
	// No marker on stderr (a wrapper that drops stderr): the capped exit code still names step k.
	if k, rc, ok := failedFromExit(92, nil); !ok || k != 2 || rc != nil {
		t.Fatalf("got %d %v %v", k, rc, ok)
	}
	tail := []byte("E15_FAILED_STEP=41 RC=2\n")
	if k, rc, ok := failedFromExit(125, tail); !ok || k != 41 || rc == nil || *rc != 2 {
		t.Fatalf("got %d %v %v", k, rc, ok)
	}
}

func TestAppendTailBounded(t *testing.T) {
	var tail []byte
	tail = appendTail(tail, []byte("E15_FAILED_STEP=3 "))
	tail = appendTail(tail, []byte("RC=2\n")) // a marker split across two chunks
	if k, rc, ok := ParseFailedMarker(tail); !ok || k != 3 || rc != 2 {
		t.Fatalf("split marker lost: %q", tail)
	}
	tail = appendTail(tail, bytes.Repeat([]byte("y"), 3000))
	tail = appendTail(tail, bytes.Repeat([]byte("z"), 3000))
	if len(tail) != stderrTailMax || tail[len(tail)-1] != 'z' || tail[0] != 'y' {
		t.Fatalf("tail len %d, want the last %d bytes", len(tail), stderrTailMax)
	}
	tail = appendTail(tail, bytes.Repeat([]byte("w"), 10000))
	if len(tail) != stderrTailMax || bytes.ContainsAny(tail, "yz") {
		t.Fatalf("an over-size chunk did not replace the tail")
	}
}

func TestValidatePlansRefusesOversizeScript(t *testing.T) {
	client, f := newFake(t)
	big := strings.Repeat("x", 400)
	// 100 distinct ~400-byte invocations of 10 ms, picked at random: 200 steps over ~90 distinct
	// commands, so even grouped into loops the script is tens of KiB, over the frame.
	inv := make([]Invocation, 100)
	for i := range inv {
		inv[i] = Invocation{ID: strconv.Itoa(i), Cmd: fmt.Sprintf(": %d%s", i, big), NominalMs: 10}
	}
	lib := &Library{Classes: map[string][]Invocation{"q": inv}}
	lib.Standin.InterpreterClass = "q"
	ss := []Session{sess("ok", "u", 20, "q", "q", "q")}
	ss[0].Calls[2].WorkMs = 2000
	var b bytes.Buffer
	_, err := NewReplayer(baseCfg(), ss, lib, client, NewRecorder(&b, &b, &b))
	if err == nil || !strings.Contains(err.Error(), "1 call") || !strings.Contains(err.Error(), "30720") {
		t.Fatalf("got %v, want a refusal naming 1 call over the 30720-byte limit", err)
	}
	if len(f.byKey()) != 0 {
		t.Fatal("execs were sent")
	}
}

func TestValidatePlansChecksEncodedFrame(t *testing.T) {
	client, f := newFake(t)
	// Under 30 KiB raw, over it encoded: '<' is 6 bytes once json.Marshal escapes it.
	lib := &Library{Classes: map[string][]Invocation{"q": {{ID: "a", Cmd: ": " + strings.Repeat("<", 6000), NominalMs: 10}}}}
	lib.Standin.InterpreterClass = "q"
	ss := []Session{sess("ok", "u", 20, "q", "q", "q")}
	script, _ := JoinPlan([]Planned{{Cmd: lib.Classes["q"][0].Cmd}}, 0)
	if len(script) > maxJoinedBytes || guestFrameBytes(script) <= maxJoinedBytes {
		t.Fatalf("fixture: raw %d, encoded %d; want raw under and encoded over %d", len(script), guestFrameBytes(script), maxJoinedBytes)
	}
	var b bytes.Buffer
	_, err := NewReplayer(baseCfg(), ss, lib, client, NewRecorder(&b, &b, &b))
	if err == nil || !strings.Contains(err.Error(), "encoded") || !strings.Contains(err.Error(), "30720") {
		t.Fatalf("got %v, want a refusal on the encoded guest frame size", err)
	}
	if len(f.byKey()) != 0 {
		t.Fatal("execs were sent")
	}
}

func TestStartAtZero(t *testing.T) {
	for seed := int64(1); seed <= 8; seed++ {
		client, _ := newFake(t)
		cfg := baseCfg()
		cfg.Seed, cfg.StartAtZero, cfg.Window = seed, true, 300*time.Millisecond
		res := run(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q", "q", "q", "q", "q", "q")}, testLib(nil, "q"), client)
		if res.err != nil || len(res.calls) == 0 || res.calls[0].Call != 0 {
			t.Fatalf("seed %d: %v first call %+v, want call 0", seed, res.err, res.calls)
		}
	}
}

func TestMaxSessionsEndsRunEarly(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.StartAtZero, cfg.MaxSessions, cfg.Window = true, 1, 20*time.Second
	t0 := time.Now()
	res := run(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil || len(res.calls) != 3 {
		t.Fatalf("%v: %d calls, want exactly 3", res.err, len(res.calls))
	}
	if d := time.Since(t0); d > 10*time.Second {
		t.Fatalf("run took %v, want it to end before the 20 s window", d)
	}
}
