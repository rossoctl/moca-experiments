package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"net"
	"strconv"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	"bytes"
	"encoding/json"
	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
	"os"
	"strings"
	"testing"
	"time"
)

const defaultPathGolden = "testdata/default-path-calls.golden.jsonl"

// TestDefaultPathUnchanged is E17B-R6's guard (E17B-R4): without --lease-mode the driver writes the
// calls.jsonl rows it always wrote. A fixed scenario (one session, one ok call, one exit mismatch,
// one ok call; MaxSessions 1 so the row count is not timing-dependent) is compared, field by
// field but for the three timing fields, to a golden captured from the driver BEFORE lease mode
// existed, and the lease fields must be absent from every row (omitempty).
func TestDefaultPathUnchanged(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window, cfg.MaxSessions = 2*time.Second, 1
	var cb, sb, pb_ bytes.Buffer
	rec := NewRecorder(&cb, &sb, &pb_)
	r, err := NewReplayer(cfg, []Session{sess("s", "u", 20, "q", "exit1", "q")}, testLib(map[string]int32{}, "q", "exit1"), client, rec)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Run(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := rec.Flush(); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, line := range strings.Split(strings.TrimSpace(cb.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatal(err)
		}
		for _, f := range []string{"ts", "t_ms", "observed_ms"} {
			if _, ok := m[f]; !ok {
				t.Fatalf("row lacks %s: %s", f, line)
			}
			delete(m, f)
		}
		for _, f := range []string{"lease_events", "first_lease", "not_lease"} {
			if _, ok := m[f]; ok {
				t.Fatalf("lease field %s present with the mode off: %s", f, line)
			}
		}
		b, _ := json.Marshal(m) // map keys marshal sorted: a stable form
		got = append(got, string(b))
	}
	if len(got) != 3 {
		t.Fatalf("%d rows, want 3", len(got))
	}
	if os.Getenv("E17B_UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(defaultPathGolden, []byte(strings.Join(got, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(defaultPathGolden)
	if err != nil {
		t.Fatal(err)
	}
	if g := strings.Join(got, "\n") + "\n"; g != string(want) {
		t.Fatalf("calls.jsonl rows changed with the mode off\n got: %s\nwant: %s", g, want)
	}
}

// ---- lease mode ----

// leaseRelay is an in-process stand-in for the moca relay's sandbox path: it verifies the bearer
// the way sandbox-caller.ts does (signature, typ, exp, wrk == sandbox_id, wsk == workspace_key ==
// sbx), takes a set_mode only with a verifying set-mode token for the same sbx, and refuses a
// harness-style bearer. Per-key behaviour is injected through the maps and funcs below.
type leaseRelay struct {
	pb.UnimplementedSandboxExecServer
	key TokenKey

	mu       sync.Mutex
	execs    []leaseSeen
	setModes []leaseSeen
	statuses []leaseSeen
	resets   int
	modeSet  map[string]bool

	setModeDelay  map[string]time.Duration // per key: the ack waits this long
	refuseSetMode bool
	// execEvents is the lease events the n-th (from 0) Exec of key carries.
	execEvents func(key string, n int) []*pb.LeaseEvent
	// execFail, when set for (key, n), ends the Exec with a gRPC error after its events.
	execFail func(key string, n int) error
	// statusFor is the answer to a status call; an error fails the call.
	statusFor func(key string) (*pb.LeaseStatus, error)
}

type leaseSeen struct {
	key        string
	recv, done time.Time
	bearer     map[string]any // the bearer token's claims
	setMode    map[string]any // the set-mode token's claims, for a set_mode
	cmd        string
}

func newLeaseRelay(t *testing.T) (pb.SandboxExecClient, *leaseRelay) {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	lr := &leaseRelay{key: testTokenKey(), modeSet: map[string]bool{}, setModeDelay: map[string]time.Duration{}}
	srv := grpc.NewServer()
	pb.RegisterSandboxExecServer(srv, lr)
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
	return pb.NewSandboxExecClient(cc), lr
}

// verify checks a token of the given typ and returns its claims, or a gRPC Unauthenticated error.
func (lr *leaseRelay) verify(tok, typ string) (map[string]any, error) {
	bad := func(why string) error { return status.Error(codes.Unauthenticated, why) }
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return nil, bad("malformed token")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(lr.key.Priv.Public().(ed25519.PublicKey), []byte(parts[0]+"."+parts[1]), sig) {
		return nil, bad("bad signature")
	}
	var hdr, c map[string]any
	for i, dst := range []*map[string]any{&hdr, &c} {
		raw, err := base64.RawURLEncoding.DecodeString(parts[i])
		if err != nil || json.Unmarshal(raw, dst) != nil {
			return nil, bad("malformed token")
		}
	}
	if hdr["typ"] != typ || hdr["kid"] != lr.key.Kid() {
		return nil, bad("wrong typ or kid")
	}
	if c["iss"] != "e17b-iss" || c["aud"] != "moca-sandbox" {
		return nil, bad("wrong iss or aud")
	}
	if exp, _ := c["exp"].(float64); float64(time.Now().Unix()) >= exp {
		return nil, bad("token expired")
	}
	return c, nil
}

func bearerOf(ctx context.Context) string {
	md, _ := metadata.FromIncomingContext(ctx)
	if a := md.Get("authorization"); len(a) == 1 {
		return strings.TrimPrefix(a[0], "Bearer ")
	}
	return ""
}

func (lr *leaseRelay) Exec(req *pb.ExecRequest, stream grpc.ServerStreamingServer[pb.ExecEvent]) error {
	recv := time.Now()
	c, err := lr.verify(bearerOf(stream.Context()), "moca-sandbox+jwt")
	if err != nil {
		return err
	}
	e := req.GetExec()
	if req.GetSandboxId() != c["wrk"] || e.GetWorkspaceKey() != c["wsk"] || c["wsk"] != c["sbx"] {
		return status.Error(codes.PermissionDenied, "exec not permitted: sandbox_id or workspace_key is not this token's")
	}
	key := e.GetWorkspaceKey()
	lr.mu.Lock()
	n := 0
	for _, s := range lr.execs {
		if s.key == key {
			n++
		}
	}
	lr.execs = append(lr.execs, leaseSeen{key: key, recv: recv, bearer: c, cmd: e.GetCommand()})
	idx := len(lr.execs) - 1
	lr.mu.Unlock()
	defer func() {
		lr.mu.Lock()
		lr.execs[idx].done = time.Now()
		lr.mu.Unlock()
	}()
	if lr.execEvents != nil {
		for _, ev := range lr.execEvents(key, n) {
			if err := stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_Lease{Lease: ev}}); err != nil {
				return err
			}
		}
	}
	if lr.execFail != nil {
		if err := lr.execFail(key, n); err != nil {
			return err
		}
	}
	return stream.Send(&pb.ExecEvent{Event: &pb.ExecEvent_End{End: &pb.End{ReqId: e.GetReqId(), ExitCode: 0}}})
}

func (lr *leaseRelay) LeaseControl(ctx context.Context, req *pb.LeaseControlRequest) (*pb.LeaseControlResponse, error) {
	recv := time.Now()
	c, err := lr.verify(bearerOf(ctx), "moca-sandbox+jwt")
	if err != nil {
		return nil, err
	}
	if req.GetSandboxId() != c["wrk"] {
		return nil, status.Error(codes.PermissionDenied, "lease control not permitted: sandbox_id is not this token's worker")
	}
	key, _ := c["wsk"].(string)
	seen := leaseSeen{key: key, recv: recv, bearer: c}
	switch req.GetOp() {
	case pb.LeaseOp_LEASE_OP_SET_MODE:
		sm, err := lr.verify(req.GetSetModeToken(), "moca-sandbox-mode+jwt")
		if err != nil || sm["sbx"] != c["sbx"] || sm["wrk"] != c["wrk"] || sm["wsk"] != c["wsk"] {
			return nil, status.Error(codes.PermissionDenied, "set_mode not permitted: the set-mode token did not verify")
		}
		seen.setMode = sm
		lr.mu.Lock()
		d := lr.setModeDelay[key]
		lr.mu.Unlock()
		time.Sleep(d)
		if lr.refuseSetMode {
			return nil, status.Error(codes.FailedPrecondition, "stale_mode: refused")
		}
		lr.mu.Lock()
		lr.modeSet[key] = true
		seen.done = time.Now()
		lr.setModes = append(lr.setModes, seen)
		lr.mu.Unlock()
		return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{Mode: pb.SandboxMode_SANDBOX_MODE_LEASE, State: "none", EpochKnown: true}}, nil
	case pb.LeaseOp_LEASE_OP_STATUS:
		lr.mu.Lock()
		lr.statuses = append(lr.statuses, seen)
		lr.mu.Unlock()
		if lr.statusFor != nil {
			st, err := lr.statusFor(key)
			if err != nil {
				return nil, err
			}
			return &pb.LeaseControlResponse{Status: st}, nil
		}
		return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{State: "none"}}, nil
	case pb.LeaseOp_LEASE_OP_RESET:
		lr.mu.Lock()
		lr.resets++
		lr.mu.Unlock()
	}
	return &pb.LeaseControlResponse{Status: &pb.LeaseStatus{}}, nil
}

func (lr *leaseRelay) execsOf(key string) []leaseSeen {
	lr.mu.Lock()
	defer lr.mu.Unlock()
	var out []leaseSeen
	for _, s := range lr.execs {
		if s.key == key {
			out = append(out, s)
		}
	}
	return out
}

func (lr *leaseRelay) setModeOf(key string) (leaseSeen, bool) {
	lr.mu.Lock()
	defer lr.mu.Unlock()
	for _, s := range lr.setModes {
		if s.key == key {
			return s, true
		}
	}
	return leaseSeen{}, false
}

func leaseCfg() Config {
	cfg := baseCfg()
	cfg.Token, cfg.StartAtZero = "", true
	cfg.Lease = &LeaseConfig{Key: testTokenKey(), Iss: "e17b-iss", Wrk: "e15", IdleTimeoutS: 120, TokenTTL: 300 * time.Second}
	return cfg
}

// leaseRun runs the replay with the lease-tail writer attached and returns what was recorded.
func leaseRun(t *testing.T, cfg Config, ss []Session, lib *Library, client pb.SandboxExecClient) (result, []leaseTailRow, *Replayer) {
	t.Helper()
	var cb, sb, pb_, tb bytes.Buffer
	rec := NewRecorder(&cb, &sb, &pb_)
	rec.SetLeaseTail(&tb)
	r, err := NewReplayer(cfg, ss, lib, client, rec)
	if err != nil {
		t.Fatal(err)
	}
	runErr := r.Run(context.Background())
	if err := rec.Flush(); err != nil {
		t.Fatal(err)
	}
	return result{calls: readLines[callRecord](t, &cb), sessions: readLines[sessionRecord](t, &sb), err: runErr},
		readLines[leaseTailRow](t, &tb), r
}

func startEvent(at int64) *pb.LeaseEvent {
	return &pb.LeaseEvent{State: "start", AtUnixMs: at, Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}
}

func startsOnFirst(key string, n int) []*pb.LeaseEvent {
	if n == 0 {
		return []*pb.LeaseEvent{startEvent(1000)}
	}
	return nil
}

func TestFirstExecWaitsForSetMode(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	lr.setModeDelay["e15-t-0-0"] = 400 * time.Millisecond
	cfg := leaseCfg()
	cfg.N, cfg.Window = 3, 1500*time.Millisecond
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 50, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	for slot := 0; slot < 3; slot++ {
		key := "e15-t-" + strconv.Itoa(slot) + "-0"
		sm, ok := lr.setModeOf(key)
		ex := lr.execsOf(key)
		if !ok || len(ex) == 0 {
			t.Fatalf("%s: set_mode %v, %d execs", key, ok, len(ex))
		}
		if ex[0].recv.Before(sm.done) {
			t.Fatalf("%s: first Exec received before its set_mode was acked", key)
		}
	}
	slow, _ := lr.setModeOf("e15-t-0-0")
	if d := slow.done.Sub(slow.recv); d < 400*time.Millisecond {
		t.Fatalf("set_mode took %v, the injected delay was not applied", d)
	}
	// per-key serialization, not a global lock: another session's first Exec is not held up.
	other := lr.execsOf("e15-t-1-0")[0]
	if !other.recv.Before(slow.done) {
		t.Fatalf("session 1's first Exec waited for session 0's set_mode: a global lock")
	}
}

func TestLeaseEventsAreRecordedAndDeduped(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = func(key string, n int) []*pb.LeaseEvent {
		switch n {
		case 0, 1: // the pending start is re-delivered on the second Exec
			return []*pb.LeaseEvent{startEvent(1000)}
		case 2:
			return []*pb.LeaseEvent{{State: "end", Reason: "idle", AtUnixMs: 2000, AgeMs: 1000, Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}}
		}
		return nil
	}
	cfg := leaseCfg()
	cfg.MaxSessions = 1
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil || len(res.calls) != 4 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	if ev := res.calls[0].LeaseEvents; len(ev) != 1 || ev[0] != (leaseEvent{State: "start", AtUnixMs: 1000, Mode: "lease"}) {
		t.Fatalf("call 0 events %+v", ev)
	}
	if len(res.calls[1].LeaseEvents) != 0 {
		t.Fatalf("the re-delivered start was recorded twice: %+v", res.calls[1].LeaseEvents)
	}
	if ev := res.calls[2].LeaseEvents; len(ev) != 1 || ev[0] != (leaseEvent{State: "end", Reason: "idle", AtUnixMs: 2000, AgeMs: 1000, Mode: "lease"}) {
		t.Fatalf("call 2 events %+v", ev)
	}
	for i, c := range res.calls {
		if c.FirstLease != (i == 0) {
			t.Fatalf("call %d first_lease %v", i, c.FirstLease)
		}
		if c.NotLease {
			t.Fatalf("call %d not_lease", i)
		}
	}
}

func TestNoEndSessionInLeaseMode(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	cfg := leaseCfg()
	cfg.Window, cfg.EndSessionExec, cfg.EndSessionDefer = 300*time.Millisecond, true, true
	cfg.Grace = 100 * time.Millisecond
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil || len(res.calls) == 0 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	lr.mu.Lock()
	defer lr.mu.Unlock()
	for _, s := range lr.execs {
		if s.cmd == EndSessionCommand {
			t.Fatalf("an end-session Exec was sent on %s", s.key)
		}
	}
}

func TestStatusSweepWritesStateAndPending(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	lr.statusFor = func(key string) (*pb.LeaseStatus, error) {
		if strings.HasSuffix(key, "-0-0") {
			return &pb.LeaseStatus{State: "none", Pending: &pb.LeaseEvent{State: "end", Reason: "idle", AtUnixMs: 3000, AgeMs: 2500, Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}}, nil
		}
		return &pb.LeaseStatus{State: "active"}, nil
	}
	cfg := leaseCfg()
	cfg.N, cfg.Window = 2, 300*time.Millisecond
	res, tail, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	keys := map[string]bool{}
	for _, c := range res.calls {
		keys[c.Session] = true
	}
	if len(tail) != len(keys) || len(keys) < 2 {
		t.Fatalf("%d tail rows for %d session keys", len(tail), len(keys))
	}
	for _, row := range tail {
		if !keys[row.Key] || row.Error != "" {
			t.Fatalf("row %+v", row)
		}
		if strings.HasSuffix(row.Key, "-0-0") {
			want := leaseEvent{State: "end", Reason: "idle", AtUnixMs: 3000, AgeMs: 2500, Mode: "lease"}
			if row.State != "none" || row.Pending == nil || *row.Pending != want {
				t.Fatalf("row %+v", row)
			}
		} else if row.State != "active" || row.Pending != nil {
			t.Fatalf("row %+v", row)
		}
	}
	// the sweep's status call authenticates as the key's own sandbox token
	for _, s := range lr.statuses {
		if s.bearer["sbx"] != s.key || s.bearer["wrk"] != "e15" {
			t.Fatalf("status bearer %v for %s", s.bearer, s.key)
		}
	}
}

// E17B-R6: the sweep runs when sessions failed, and a failing status call is a row, not a gap.
func TestStatusSweepRunsAfterFailuresAndRecordsErrors(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	lr.execFail = func(key string, n int) error { return status.Error(codes.Unavailable, "connection reset by peer") }
	lr.statusFor = func(key string) (*pb.LeaseStatus, error) {
		if strings.HasSuffix(key, "-0-0") {
			return nil, status.Error(codes.DeadlineExceeded, "no answer from the worker")
		}
		return &pb.LeaseStatus{State: "expiring"}, nil
	}
	cfg := leaseCfg()
	cfg.N, cfg.Window = 2, 300*time.Millisecond
	res, tail, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	for _, c := range res.calls {
		if c.Status != "err" {
			t.Fatalf("call %+v should have failed", c)
		}
	}
	var sawErr, sawOK bool
	for _, row := range tail {
		if strings.HasSuffix(row.Key, "-0-0") {
			if row.Error == "" || row.State != "" || row.Pending != nil {
				t.Fatalf("row %+v: want {key, error}", row)
			}
			sawErr = true
		} else if row.State == "expiring" && row.Error == "" {
			sawOK = true
		}
	}
	if !sawErr || !sawOK {
		t.Fatalf("tail %+v", tail)
	}
}

func TestEventsRecordedOnFailedCalls(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = func(key string, n int) []*pb.LeaseEvent {
		if n == 0 {
			return []*pb.LeaseEvent{startEvent(1000)}
		}
		return []*pb.LeaseEvent{{State: "end", Reason: "idle", AtUnixMs: 2000, Mode: pb.SandboxMode_SANDBOX_MODE_LEASE}}
	}
	lr.execFail = func(key string, n int) error {
		if n == 1 {
			return status.Error(codes.Unavailable, "connection reset by peer")
		}
		return nil
	}
	cfg := leaseCfg()
	cfg.MaxSessions = 1
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if len(res.calls) != 3 {
		t.Fatalf("%d calls", len(res.calls))
	}
	c := res.calls[1]
	if c.Status != "err" || c.Cause != causeUnavailable {
		t.Fatalf("call 1 %+v", c)
	}
	if len(c.LeaseEvents) != 1 || c.LeaseEvents[0].State != "end" || c.LeaseEvents[0].AtUnixMs != 2000 {
		t.Fatalf("the failed call lost its end event: %+v", c.LeaseEvents)
	}
}

func TestFirstCallWithoutStartIsNotLease(t *testing.T) {
	client, lr := newLeaseRelay(t) // no events at all: the worker ran the Exec per-exec
	_ = lr
	cfg := leaseCfg()
	cfg.MaxSessions = 1
	res, _, r := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil || len(res.calls) != 3 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	for i, c := range res.calls {
		if !c.NotLease {
			t.Fatalf("call %d of a session whose first call had no start is not marked not_lease", i)
		}
	}
	if r.NotLeaseSessions() != 1 {
		t.Fatalf("NotLeaseSessions %d, want 1", r.NotLeaseSessions())
	}

	client2, lr2 := newLeaseRelay(t)
	lr2.execEvents = startsOnFirst
	res2, _, r2 := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client2)
	if res2.err != nil || r2.NotLeaseSessions() != 0 {
		t.Fatalf("err %v, NotLeaseSessions %d", res2.err, r2.NotLeaseSessions())
	}
	for _, c := range res2.calls {
		if c.NotLease {
			t.Fatalf("%+v", c)
		}
	}
}

func TestExecTokenCarriesTheSetModeEpoch(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	cfg := leaseCfg()
	cfg.MaxSessions = 1
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	key := "e15-t-0-0"
	sm, ok := lr.setModeOf(key)
	if !ok {
		t.Fatal("no set_mode")
	}
	for name, c := range map[string]map[string]any{"set-mode": sm.setMode, "bearer of set_mode": sm.bearer, "exec 0": lr.execsOf(key)[0].bearer, "exec 1": lr.execsOf(key)[1].bearer} {
		if c["mode_epoch"] != float64(1) || c["mode"] != "lease" || c["idle_timeout_s"] != float64(120) {
			t.Fatalf("%s token claims %v", name, c)
		}
		if c["sbx"] != key || c["wsk"] != key || c["wrk"] != "e15" {
			t.Fatalf("%s token binds %v / %v / %v, want %s / %s / e15", name, c["sbx"], c["wsk"], c["wrk"], key, key)
		}
	}
	if sm.setMode["tenant"] != nil || sm.setMode["scope"] != nil {
		t.Fatalf("a set-mode token carries no tenant or scope: %v", sm.setMode)
	}
}

func TestRefreshesTokenBeforeExp(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEvents = startsOnFirst
	cfg := leaseCfg()
	cfg.Lease.TokenTTL = 2 * time.Second
	cfg.MaxSessions = 1
	cfg.Window = 5 * time.Second
	calls := make([]string, 0, 30)
	for i := 0; i < 25; i++ {
		calls = append(calls, "q")
	}
	res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 200, calls...)}, testLib(nil, "q"), client)
	if res.err != nil || len(res.calls) < 20 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	jtis := map[any]bool{}
	for _, c := range res.calls {
		if c.Status != "ok" {
			t.Fatalf("call %d failed across the token's expiry: %+v", c.Call, c)
		}
	}
	for _, e := range lr.execsOf("e15-t-0-0") {
		jtis[e.bearer["jti"]] = true
	}
	if len(jtis) < 2 {
		t.Fatalf("one token served a 5 s session on a 2 s TTL")
	}
}

func TestFailsWhenSetModeRefused(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.refuseSetMode = true
	cfg := leaseCfg()
	cfg.MaxSessions = 1
	cfg.Window = 300 * time.Millisecond
	res, tail, r := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
	if res.err != nil {
		t.Fatal(res.err)
	}
	lr.mu.Lock()
	n := len(lr.execs)
	lr.mu.Unlock()
	if n != 0 {
		t.Fatalf("%d Execs were served after a refused set_mode (per-exec fallback)", n)
	}
	if len(res.calls) != 1 {
		t.Fatalf("%d call rows, want 1 failed row for the session", len(res.calls))
	}
	c := res.calls[0]
	if c.Status != "err" || c.Cause != causeSetMode || c.Execs != 0 || !strings.Contains(c.Msg, "stale_mode") {
		t.Fatalf("row %+v", c)
	}
	if len(tail) != 1 {
		t.Fatalf("the failed session is still swept: %+v", tail)
	}
	if r.NotLeaseSessions() != 0 {
		t.Fatalf("a refused set_mode is not a not_lease session")
	}
}

func TestLeaseModeFlags(t *testing.T) {
	var buf bytes.Buffer
	base := []string{"--corpus", "x", "--library", "y", "--run-id", "r", "--out", t.TempDir(), "--n", "1", "--lease-mode", "--idle-timeout-s", "120"}
	for name, c := range map[string]struct {
		extra []string
		want  string
	}{
		"no issuer":    {[]string{"--token-key", "k"}, "--token-iss is required"},
		"no key":       {[]string{"--token-iss", "i"}, "--token-key is required"},
		"wrk mismatch": {[]string{"--token-key", "k", "--token-iss", "i", "--token-wrk", "other"}, "must equal --sandbox-id"},
		"no idle":      {[]string{"--token-key", "k", "--token-iss", "i", "--idle-timeout-s", "0"}, "--idle-timeout-s"},
	} {
		buf.Reset()
		if code := realMain(append(append([]string{}, base...), c.extra...), func(string) string { return "" }, &buf); code != 2 || !strings.Contains(buf.String(), c.want) {
			t.Fatalf("%s: exit %d, want 2 with %q: %s", name, code, c.want, buf.String())
		}
	}
}
