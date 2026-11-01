package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
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

// fake is an in-process SandboxExecServer whose behaviour is chosen by the command text:
// "hold:<ms>" holds then ends 0; "exit1" ends 1; "inerr" sends an in-stream ExecError and returns
// OK (what the relay does); "nolive" returns the relay's Unavailable refusal; anything else ends 0.
type fake struct {
	pb.UnimplementedSandboxExecServer
	mu    sync.Mutex
	execs []fakeExec
}

func (f *fake) Exec(req *pb.ExecRequest, stream grpc.ServerStreamingServer[pb.ExecEvent]) error {
	recv := time.Now()
	md, _ := metadata.FromIncomingContext(stream.Context())
	if a := md.Get("authorization"); len(a) != 1 || a[0] != "Bearer "+testToken {
		return status.Error(codes.Unauthenticated, "bad bearer")
	}
	e := req.GetExec()
	if req.GetSandboxId() != "e15" || e.GetWorkspaceKey() == "" || e.GetTimeoutS() < 120 {
		return status.Error(codes.InvalidArgument, "bad request")
	}
	defer func() {
		f.mu.Lock()
		f.execs = append(f.execs, fakeExec{e.GetWorkspaceKey(), e.GetCommand(), recv, time.Now()})
		f.mu.Unlock()
	}()
	end := func(code int32) error {
		return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_End{End: &pb.End{ReqId: e.GetReqId(), ExitCode: code}}})
	}
	cmd := e.GetCommand()
	switch {
	case strings.HasPrefix(cmd, "hold:"):
		ms, _ := strconv.Atoi(strings.TrimPrefix(cmd, "hold:"))
		time.Sleep(time.Duration(ms) * time.Millisecond)
		return end(0)
	case cmd == "exit1":
		return end(1)
	case cmd == "inerr":
		return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Error{Error: &pb.ExecError{ReqId: e.GetReqId(), Message: "boom"}}})
	case cmd == "nolive":
		return status.Error(codes.Unavailable, "no live worker for sandbox 'e15'")
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
	return Config{N: 1, Seed: 7, UserCap: 1, Window: time.Second, Spread: 0, SandboxID: "e15", RunID: "t", Token: testToken}
}

func newReplay(t *testing.T, cfg Config, ss []Session, lib *Library, client pb.SandboxExecClient) (*Replayer, func() result) {
	t.Helper()
	var cb, sb, pb_ bytes.Buffer
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
		return result{readLines[callRecord](t, &cb), readLines[sessionRecord](t, &sb), readLines[cpuRecord](t, &pb_), err}
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
		if c.Status != tc.status || c.Cause != tc.cause || c.Exit == nil || *c.Exit != 1 || c.ExpectedExit != tc.expect {
			t.Fatalf("expect %d: got %+v", tc.expect, c)
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
	if res.err != nil || len(res.cpu) < 2 || res.cpu[len(res.cpu)-1].UtimeMs+res.cpu[len(res.cpu)-1].StimeMs <= 0 {
		t.Fatalf("%v %+v", res.err, res.cpu)
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
