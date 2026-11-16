package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

// ---- the ownership-walk probe (spec §7.4) ----

// owClock is the fake relay's clock: the relay advances it by each op's simulated cost while the
// driver waits on the call, so the driver's timings are exact.
type owClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *owClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *owClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// owOp is one call the fake relay accepted, in arrival order.
type owOp struct {
	key   string
	op    string // exec | set_mode | reset | status
	mode  string // exec: the bearer's mode claim; set_mode: the set-mode token's
	epoch int    // the same, mode_epoch
	cmd   string
}

// owKeyState is the worker side of one workspace key, as remote-worker's vmpool keeps it
// (lease_state.go, lease.go): unknown until set_mode, root_wrote when set_mode finds no state
// (ruling R7), a lease that a reset ends with a pending end(reset), and a start notice only
// when no end is pending.
type owKeyState struct {
	known, rootWrote, live bool
	epoch                  int
	pending                *pb.LeaseEvent
}

// owRelay is an in-process stand-in for the moca relay's sandbox path and the worker behind it.
// The relay half mirrors packages/sandbox-relay/src/sandbox-caller.ts: the bearer is a verified
// sandbox token, sandbox_id == its wrk, workspace_key == its wsk; a LeaseControl is on the
// token's own workspace, a set_mode only with a verifying set-mode token for the same
// sbx/wrk/wsk, a reset with no set-mode token and no mode or epoch; the Exec's mode and epoch
// come from the bearer's claims, never from the client.
type owRelay struct {
	pb.UnimplementedSandboxExecServer
	v     *leaseRelay // its verify only
	clock *owClock

	mu    sync.Mutex
	ops   []owOp
	state map[string]*owKeyState
	reps  map[string]int // key -> repeat index, in first-seen order

	cold    func(rep int) time.Duration // a lease Exec that starts a VM
	walk    func(rep int) time.Duration // the ownership walk, when root_wrote
	execDur time.Duration               // the command itself
	build   time.Duration               // the per-exec tree build
	// buildExit, when set, is the per-exec build's exit code for a repeat.
	buildExit func(rep int) int32
	// skipResetEnd drops the end(reset) notice (a worker that never reports it).
	skipResetEnd bool
}

func newOwRelay(t *testing.T) (pb.SandboxExecClient, *owRelay) {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	r := &owRelay{
		v: &leaseRelay{key: testTokenKey()}, clock: &owClock{t: time.Unix(1_700_000_000, 0)},
		state: map[string]*owKeyState{}, reps: map[string]int{},
		cold:    func(int) time.Duration { return 100 * time.Millisecond },
		walk:    func(int) time.Duration { return 400 * time.Millisecond },
		execDur: 5 * time.Millisecond, build: 2 * time.Second,
	}
	srv := grpc.NewServer()
	pb.RegisterSandboxExecServer(srv, r)
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
	return pb.NewSandboxExecClient(cc), r
}

func claimInt(c map[string]any, k string) int {
	f, _ := c[k].(float64)
	return int(f)
}

func (r *owRelay) keyState(key string) (*owKeyState, int) {
	s := r.state[key]
	if s == nil {
		s = &owKeyState{}
		r.state[key] = s
	}
	rep, ok := r.reps[key]
	if !ok {
		rep = len(r.reps)
		r.reps[key] = rep
	}
	return s, rep
}

func (r *owRelay) Exec(req *pb.ExecRequest, stream grpc.ServerStreamingServer[pb.ExecEvent]) error {
	c, err := r.v.verify(bearerOf(stream.Context()), "moca-sandbox+jwt")
	if err != nil {
		return err
	}
	e := req.GetExec()
	if req.GetSandboxId() != c["wrk"] {
		return status.Error(codes.PermissionDenied, "exec not permitted: sandbox_id is not this token's worker")
	}
	if e.GetWorkspaceKey() != c["wsk"] {
		return status.Error(codes.PermissionDenied, "exec not permitted: workspace_key is not this token's workspace")
	}
	key := e.GetWorkspaceKey()
	mode, _ := c["mode"].(string)
	epoch := claimInt(c, "mode_epoch")
	r.mu.Lock()
	r.ops = append(r.ops, owOp{key: key, op: "exec", mode: mode, epoch: epoch, cmd: e.GetCommand()})
	s, rep := r.keyState(key)
	var cost time.Duration
	var events []*pb.LeaseEvent
	var stdout string
	exit := int32(0)
	switch {
	case mode == "per-exec" || !s.known:
		// per-Exec: a fresh VM, as root. An unknown state runs per-Exec whatever the token says
		// (lease_state.go: "mode per-exec until set_mode"), and records nothing.
		cost = r.build
		if s.known {
			s.rootWrote = true
		}
		if f := strings.Fields(e.GetCommand()); strings.Contains(e.GetCommand(), "build_tree.sh") && len(f) > 0 {
			stdout = "build_tree: files=" + f[len(f)-1] + " dirs=1\n"
		}
		if r.buildExit != nil {
			exit = r.buildExit(rep)
		}
	case epoch < s.epoch:
		r.mu.Unlock()
		return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Error{Error: &pb.ExecError{ReqId: e.GetReqId(), Message: "stale_mode: epoch below the stored one"}}})
	case !s.live:
		cost = r.cold(rep) + r.execDur
		if s.rootWrote {
			cost += r.walk(rep)
			s.rootWrote = false
		}
		s.live = true
		if s.pending == nil || s.pending.GetState() != "end" {
			s.pending = &pb.LeaseEvent{State: "start", AtUnixMs: r.clock.Now().UnixMilli(), Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}
		}
		events = []*pb.LeaseEvent{s.pending}
		s.pending = nil // acknowledged once queued on the stream
	default:
		cost = r.execDur
	}
	r.mu.Unlock()
	r.clock.advance(cost)
	for _, ev := range events {
		if err := stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Lease{Lease: ev}}); err != nil {
			return err
		}
	}
	if stdout != "" {
		if err := stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Chunk{Chunk: &pb.Chunk{ReqId: e.GetReqId(), Stream: pb.Stream_STREAM_STDOUT, Data: []byte(stdout)}}}); err != nil {
			return err
		}
	}
	return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_End{End: &pb.End{ReqId: e.GetReqId(), ExitCode: exit}}})
}

func (r *owRelay) LeaseControl(ctx context.Context, req *pb.LeaseControlRequest) (*pb.LeaseControlResponse, error) {
	c, err := r.v.verify(bearerOf(ctx), "moca-sandbox+jwt")
	if err != nil {
		return nil, err
	}
	if req.GetSandboxId() != c["wrk"] {
		return nil, status.Error(codes.PermissionDenied, "lease control not permitted: sandbox_id is not this token's worker")
	}
	key, _ := c["wsk"].(string)
	r.mu.Lock()
	defer r.mu.Unlock()
	s, _ := r.keyState(key)
	switch req.GetOp() {
	case pb.LeaseOp_LEASE_OP_SET_MODE:
		sm, err := r.v.verify(req.GetSetModeToken(), "moca-sandbox-mode+jwt")
		if err != nil || sm["sbx"] != c["sbx"] || sm["wrk"] != c["wrk"] || sm["wsk"] != c["wsk"] {
			return nil, status.Error(codes.PermissionDenied, "set_mode not permitted: the set-mode token did not verify")
		}
		mode, _ := sm["mode"].(string)
		epoch := claimInt(sm, "mode_epoch")
		r.ops = append(r.ops, owOp{key: key, op: "set_mode", mode: mode, epoch: epoch})
		if s.known && epoch < s.epoch {
			return nil, status.Error(codes.FailedPrecondition, "stale_mode: epoch below the stored one")
		}
		if !s.known {
			s.rootWrote = true // ruling R7: no state means an unknown history
		}
		s.known, s.epoch = true, epoch
		return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{Mode: pb.SandboxMode_SANDBOX_MODE_LEASE, EpochKnown: true, State: "none"}}, nil
	case pb.LeaseOp_LEASE_OP_RESET:
		r.ops = append(r.ops, owOp{key: key, op: "reset"})
		if s.live {
			s.live = false
			if !r.skipResetEnd {
				s.pending = &pb.LeaseEvent{State: "end", Reason: "reset", AtUnixMs: r.clock.Now().UnixMilli(), Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}
			}
		}
		// The worker answers with the status after the op: no lease, the end(reset) pending (runner.go LeaseControl).
		return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{Mode: pb.SandboxMode_SANDBOX_MODE_LEASE, EpochKnown: true, State: "none", Pending: s.pending}}, nil
	case pb.LeaseOp_LEASE_OP_STATUS:
		r.ops = append(r.ops, owOp{key: key, op: "status"})
		return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{State: "none"}}, nil
	}
	return nil, status.Error(codes.InvalidArgument, "lease control needs an op")
}

const owScript = "#!/bin/sh\n# build_tree.sh stand-in\necho 'it''s here'\n"

func owCfg(r *owRelay) OwnwalkConfig {
	return OwnwalkConfig{
		Files: 10000, Repeats: 5, SandboxID: "e15", RunID: "ow-t", Key: testTokenKey(), Iss: "e17b-iss",
		IdleTimeoutS: 300, BuildScript: owScript, TreeDir: "/workspace/ownwalk-tree", ProbeCmd: "true",
		BuildTimeoutS: 3600, ExecTimeoutS: 900, Now: r.clock.Now,
	}
}

func TestOwnwalkOrdersTheSteps(t *testing.T) {
	client, relay := newOwRelay(t)
	cfg := owCfg(relay)
	rep, err := RunOwnwalk(context.Background(), client, cfg)
	if err != nil {
		t.Fatal(err)
	}
	wantBuild := ownwalkBuildCmd(owScript, "/workspace/ownwalk-tree", 10000)
	var want []owOp
	for i := 0; i < cfg.Repeats; i++ {
		k := ownwalkKey("ow-t", i)
		want = append(want,
			owOp{key: k, op: "exec", mode: "per-exec", epoch: 0, cmd: wantBuild}, // the per-exec write, as root
			owOp{key: k, op: "set_mode", mode: "lease", epoch: 1},                // per-exec -> lease, epoch +1
			owOp{key: k, op: "exec", mode: "lease", epoch: 1, cmd: "true"},       // A: the first lease Exec (the walk)
			owOp{key: k, op: "reset"},                                            // the lease ends, its state clean
			owOp{key: k, op: "exec", mode: "lease", epoch: 1, cmd: "true"},       // B: a cold lease Exec, no walk
		)
	}
	relay.mu.Lock()
	got := append([]owOp(nil), relay.ops...)
	relay.mu.Unlock()
	if len(got) != len(want) {
		t.Fatalf("%d ops, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("op %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	keys := map[string]bool{}
	for _, run := range rep.Runs {
		keys[run.Key] = true
		if !run.Valid {
			t.Errorf("repeat %d invalid: %v", run.Rep, run.InvalidReasons)
		}
		if !hasStart(run.A.Events) {
			t.Errorf("repeat %d: A carried no lease start: %+v", run.Rep, run.A.Events)
		}
		if len(run.B.Events) != 1 || run.B.Events[0].State != "end" || run.B.Events[0].Reason != "reset" {
			t.Errorf("repeat %d: B events %+v, want the end(reset) notice", run.Rep, run.B.Events)
		}
		if st := run.Reset.Status; st == nil || st.State != "none" || st.Mode != "lease" || !st.EpochKnown ||
			st.Pending == nil || st.Pending.State != "end" || st.Pending.Reason != "reset" {
			t.Errorf("repeat %d: reset status %+v, want no lease with the end(reset) pending", run.Rep, st)
		}
		if !strings.Contains(run.Build.Stdout, "files=10000") {
			t.Errorf("repeat %d: build stdout %q", run.Rep, run.Build.Stdout)
		}
	}
	if len(keys) != cfg.Repeats {
		t.Errorf("%d distinct workspace keys over %d repeats, want a fresh one each", len(keys), cfg.Repeats)
	}
	if !rep.Valid {
		t.Errorf("report invalid: %v", rep.InvalidReasons)
	}
}

func TestOwnwalkReportsAMinusB(t *testing.T) {
	client, relay := newOwRelay(t)
	colds := []int{100, 110, 90, 105, 95}
	walks := []int{400, 380, 420, 410, 390}
	relay.cold = func(rep int) time.Duration { return time.Duration(colds[rep]) * time.Millisecond }
	relay.walk = func(rep int) time.Duration { return time.Duration(walks[rep]) * time.Millisecond }
	cfg := owCfg(relay)
	rep, err := RunOwnwalk(context.Background(), client, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Runs) != 5 {
		t.Fatalf("%d runs, want 5", len(rep.Runs))
	}
	for i, run := range rep.Runs {
		a := float64(colds[i] + walks[i] + 5)
		b := float64(colds[i] + 5)
		if run.AMs == nil || *run.AMs != a || run.BMs == nil || *run.BMs != b || run.WalkMs == nil || *run.WalkMs != a-b {
			t.Errorf("repeat %d: a %v b %v walk %v, want %v %v %v", i, deref(run.AMs), deref(run.BMs), deref(run.WalkMs), a, b, a-b)
		}
		if run.A.Ms != a || run.B.Ms != b {
			t.Errorf("repeat %d: step ms a %v b %v", i, run.A.Ms, run.B.Ms)
		}
	}
	// medians of the 5: A {505,495,515,520,490} -> 505; B {105,115,95,110,100} -> 105; A-B {400,380,420,410,390} -> 400
	for name, got := range map[string]*float64{"median_a_ms": rep.MedianAMs, "median_b_ms": rep.MedianBMs, "median_walk_ms": rep.MedianWalkMs} {
		want := map[string]float64{"median_a_ms": 505, "median_b_ms": 105, "median_walk_ms": 400}[name]
		if got == nil || *got != want {
			t.Errorf("%s = %v, want %v", name, deref(got), want)
		}
	}
	// the JSON the rig keeps: ownwalk.json
	dir := t.TempDir()
	if err := writeOwnwalk(filepath.Join(dir, "ownwalk.json"), rep); err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	b, _ := os.ReadFile(filepath.Join(dir, "ownwalk.json"))
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"files", "repeats", "runs", "median_a_ms", "median_b_ms", "median_walk_ms", "valid", "build_script_sha256", "idle_timeout_s"} {
		if _, ok := m[k]; !ok {
			t.Errorf("ownwalk.json lacks %s", k)
		}
	}
	if m["median_walk_ms"] != 400.0 || m["files"] != 10000.0 || m["valid"] != true {
		t.Errorf("ownwalk.json: median_walk_ms %v files %v valid %v", m["median_walk_ms"], m["files"], m["valid"])
	}
	run0 := m["runs"].([]any)[0].(map[string]any)
	for _, k := range []string{"key", "a_ms", "b_ms", "walk_ms", "build", "set_mode", "a", "reset", "b", "valid"} {
		if _, ok := run0[k]; !ok {
			t.Errorf("ownwalk.json runs[0] lacks %s", k)
		}
	}
}

func deref(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

func TestOwnwalkMedianOfFive(t *testing.T) {
	for _, c := range []struct {
		in   []float64
		want float64
	}{{[]float64{5, 1, 4, 2, 3}, 3}, {[]float64{4, 1, 3, 2}, 2.5}, {[]float64{7}, 7}} {
		if got := median(c.in); got != c.want {
			t.Errorf("median(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

// A failed step stops the probe: nothing after it is sent, the report is invalid and says why.
func TestOwnwalkStopsOnAFailedBuild(t *testing.T) {
	client, relay := newOwRelay(t)
	relay.buildExit = func(rep int) int32 {
		if rep == 1 {
			return 1
		}
		return 0
	}
	rep, err := RunOwnwalk(context.Background(), client, owCfg(relay))
	if err == nil {
		t.Fatal("want an error for the failed build")
	}
	if rep.Valid || len(rep.Runs) != 2 || rep.Runs[1].Build.Error == "" || rep.MedianWalkMs != nil {
		t.Fatalf("report after a failed build: valid %v runs %d build error %q median %v", rep.Valid, len(rep.Runs), rep.Runs[len(rep.Runs)-1].Build.Error, deref(rep.MedianWalkMs))
	}
	relay.mu.Lock()
	n := len(relay.ops)
	last := relay.ops[n-1]
	relay.mu.Unlock()
	if n != 6 || last.op != "exec" || last.mode != "per-exec" {
		t.Errorf("%d ops, last %+v: want the first repeat's 5 and the failed build, then nothing", n, last)
	}
}

// B without the end(reset) notice is not known to have followed a reset: invalid, still measured.
func TestOwnwalkFlagsAMissingResetEnd(t *testing.T) {
	client, relay := newOwRelay(t)
	relay.skipResetEnd = true
	cfg := owCfg(relay)
	cfg.Repeats = 1
	rep, err := RunOwnwalk(context.Background(), client, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Valid || rep.Runs[0].Valid || rep.Runs[0].WalkMs == nil {
		t.Fatalf("valid %v run valid %v walk %v: want invalid but measured", rep.Valid, rep.Runs[0].Valid, deref(rep.Runs[0].WalkMs))
	}
	if !strings.Contains(strings.Join(rep.Runs[0].InvalidReasons, ";"), "reset") {
		t.Errorf("reasons %v do not name the missing reset end", rep.Runs[0].InvalidReasons)
	}
	if rep.MedianWalkMs != nil {
		t.Errorf("median reported over an invalid repeat: %v", *rep.MedianWalkMs)
	}
}

func TestOwnwalkBuildCommandRunsTheScript(t *testing.T) {
	got := ownwalkBuildCmd(owScript, "/workspace/ownwalk-tree", 500000)
	want := "sh -c '#!/bin/sh\n# build_tree.sh stand-in\necho '\\''it'\\'''\\''s here'\\''\n' build_tree.sh '/workspace/ownwalk-tree' 500000"
	if got != want {
		t.Fatalf("build command\n got %q\nwant %q", got, want)
	}
	if k := ownwalkKey("ownwalk-F10000-1", 3); k != "ownwalk-F10000-1-3" {
		t.Errorf("key %q", k)
	}
}

func TestOwnwalkFlags(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "build_tree.sh")
	if err := os.WriteFile(script, []byte(owScript), 0o644); err != nil {
		t.Fatal(err)
	}
	keyDir := filepath.Join(dir, "tok")
	var kb bytes.Buffer
	if code := realMain([]string{"mint-key", "--out", keyDir}, func(string) string { return "" }, &kb); code != 0 {
		t.Fatal(kb.String())
	}
	base := []string{"ownwalk", "--files", "10000", "--token-key", filepath.Join(keyDir, "token.key"), "--token-iss", "e17b-iss",
		"--idle-timeout-s", "300", "--run-id", "ow", "--out", dir, "--build-script", script, "--target", "127.0.0.1:1"}
	for name, c := range map[string]struct {
		args []string
		want string
	}{
		"files not one of the three": {replace(base, "10000", "12345"), "--files must be 10000, 100000 or 500000"},
		"no issuer":                  {replace(base, "e17b-iss", ""), "--token-iss is required"},
		"no idle timeout":            {replace(base, "300", "0"), "--idle-timeout-s >= 1"},
		"no run id":                  {replace(base, "ow", ""), "--run-id"},
		"no build script":            {replace(base, script, filepath.Join(dir, "missing.sh")), "build script"},
		"repeats below one":          {append(append([]string(nil), base...), "--repeats", "0"), "--repeats >= 1"},
	} {
		var buf bytes.Buffer
		if code := realMain(c.args, func(string) string { return "" }, &buf); code != 2 || !strings.Contains(buf.String(), c.want) {
			t.Errorf("%s: exit %d, stderr %q (want 2 and %q)", name, code, buf.String(), c.want)
		}
	}
}

func replace(args []string, old, new string) []string {
	out := append([]string(nil), args...)
	for i, a := range out {
		if a == old {
			out[i] = new
			return out
		}
	}
	panic("no " + old)
}

// End to end over a real listener: the subcommand writes ownwalk.json and exits 0.
func TestOwnwalkMainWritesTheReport(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	keyDir := filepath.Join(dir, "tok")
	var kb bytes.Buffer
	if code := realMain([]string{"mint-key", "--out", keyDir}, func(string) string { return "" }, &kb); code != 0 {
		t.Fatal(kb.String())
	}
	k, err := LoadTokenKey(filepath.Join(keyDir, "token.key"))
	if err != nil {
		t.Fatal(err)
	}
	relay := &owRelay{
		v: &leaseRelay{key: k}, clock: &owClock{t: time.Now()}, state: map[string]*owKeyState{}, reps: map[string]int{},
		cold: func(int) time.Duration { return 0 }, walk: func(int) time.Duration { return 0 },
	}
	srv := grpc.NewServer()
	pb.RegisterSandboxExecServer(srv, relay)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	script := filepath.Join(dir, "build_tree.sh")
	if err := os.WriteFile(script, []byte(owScript), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out")
	var buf bytes.Buffer
	code := realMain([]string{"ownwalk", "--files", "100000", "--repeats", "2", "--token-key", filepath.Join(keyDir, "token.key"),
		"--token-iss", "e17b-iss", "--idle-timeout-s", "300", "--run-id", "ow-main", "--out", out, "--build-script", script,
		"--target", lis.Addr().String(), "--sandbox-id", "e15"}, func(string) string { return "" }, &buf)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, buf.String())
	}
	var rep OwnwalkReport
	b, err := os.ReadFile(filepath.Join(out, "ownwalk.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &rep); err != nil {
		t.Fatal(err)
	}
	if rep.Files != 100000 || rep.Repeats != 2 || len(rep.Runs) != 2 || !rep.Valid || rep.Runs[1].Key != "ow-main-1" {
		t.Fatalf("ownwalk.json: %+v", rep)
	}
	relay.mu.Lock()
	first := relay.ops[0]
	relay.mu.Unlock()
	if want := strconv.Itoa(100000); !strings.HasSuffix(first.cmd, " "+want) {
		t.Errorf("build command %q does not end with the file count", first.cmd)
	}
	if !strings.Contains(buf.String(), "median walk") {
		t.Errorf("stderr lacks the summary line: %q", buf.String())
	}
}
