package main

// E17d (PLAN-E17D Task 4, spec §14.2): the process kinds and the level-2 restart rule, against the fake relay.

import (
	"strconv"
	"strings"
	"sync"
	"testing"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const (
	l2ClientLight = "cd project && ../venv/bin/python l2c.py light"
	l2ShortCmd    = "cd project && grep -rn def src"
)

// l2Lib is library-l2.json's shape: py_requery runs the client, py_short a plain command.
func l2Lib() *Library {
	l := &Library{Classes: map[string][]Invocation{
		"py_requery": {{ID: "requery_light", Cmd: l2ClientLight, NominalMs: 1}},
		"py_short":   {{ID: "grep_def", Cmd: l2ShortCmd, NominalMs: 1}},
	}}
	l.Standin.InterpreterClass = "py_short"
	return l
}

func l2Cfg(restart bool) Config {
	cfg := leaseCfg()
	cfg.Lease.Mode = leaseModeL2
	cfg.Lease.L2Restart = restart
	cfg.MaxSessions = 1
	return cfg
}

// guest is the fake guest of one key: whether a server answers, and what each client call exits with when it does.
type guest struct {
	mu        sync.Mutex
	up        bool
	startFail bool
	// clientExit, when set, is the client's exit for its n-th run (0-based over client runs) given the server state;
	// default: 0 with a server, 3 without.
	clientExit func(run int, up bool) int32
	runs       int
	afterStart bool // the server stays down after a start (a second exit 3)
}

func (g *guest) end(_ string, _ int, e *pb.Exec) (int32, string, string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch e.GetKind() {
	case pb.ExecKind_EXEC_KIND_PROCESS_START:
		if g.startFail {
			return 1, "", "process_start: refused"
		}
		g.up = !g.afterStart
		return 0, `{"id":"1","name":"l2srv","pid":42}`, ""
	case pb.ExecKind_EXEC_KIND_PROCESS_LIST:
		return 0, `[{"id":"1","name":"l2srv","pid":41,"state":"killed","code":9}]`, ""
	}
	if !strings.Contains(e.GetCommand(), "l2c.py") {
		return 0, "", ""
	}
	run := g.runs
	g.runs++
	code := int32(0)
	if !g.up {
		code = 3
	}
	if g.clientExit != nil {
		code = g.clientExit(run, g.up)
	}
	if code == 0 {
		return 0, "light groups=100 server_ms=180\n", ""
	}
	return stepExitBase, "", "l2c: ...\nE15_FAILED_STEP=0 RC=" + itoa(int(code)) + "\n"
}

func itoa(n int) string { return strconv.Itoa(n) }

func kinds(es []leaseSeen) []pb.ExecKind {
	out := make([]pb.ExecKind, len(es))
	for i, e := range es {
		out[i] = e.kind
	}
	return out
}

func TestL2RestartStartsTheServerOnceAndRerunsWithWait(t *testing.T) {
	client, lr := newLeaseRelay(t)
	g := &guest{}
	lr.execEnd = g.end
	lr.execEvents = startsOnFirst
	res, _, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_requery", "py_requery", "py_short")}, l2Lib(), client)
	if res.err != nil || len(res.calls) != 3 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	es := lr.execsOf("e15-t-0-0")
	want := []pb.ExecKind{pb.ExecKind_EXEC_KIND_COMMAND, pb.ExecKind_EXEC_KIND_PROCESS_START, pb.ExecKind_EXEC_KIND_COMMAND, pb.ExecKind_EXEC_KIND_COMMAND, pb.ExecKind_EXEC_KIND_COMMAND}
	if got := kinds(es); len(got) != len(want) || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] || got[3] != want[3] {
		t.Fatalf("exec kinds %v, want %v (client, start, client --wait, then the warm call)", got, want)
	}
	st := es[1]
	if st.cmd != "../venv/bin/python l2srv.py" || st.process.GetName() != "l2srv" || st.process.GetCwd() != "/workspace/project" {
		t.Fatalf("process_start: command %q, args %+v", st.cmd, st.process)
	}
	if !strings.Contains(es[2].cmd, "l2c.py light --wait 60") || strings.Contains(es[0].cmd, "--wait") || strings.Contains(es[3].cmd, "--wait") {
		t.Fatalf("only the re-run carries --wait 60: %q / %q / %q", es[0].cmd, es[2].cmd, es[3].cmd)
	}
	if es[1].bearer["mode"] != leaseModeL2 {
		t.Fatalf("the start's token mode %v", es[1].bearer["mode"])
	}
	c0, c1 := res.calls[0], res.calls[1]
	if c0.Status != "ok" || !c0.Restart || c0.RestartKind != "lease_cold" || c0.StartMs == nil || c0.Execs != 3 {
		t.Fatalf("the first call is a lease-cold restart: %+v", c0)
	}
	if *c0.StartMs <= 0 || *c0.StartMs > c0.ObservedMs {
		t.Fatalf("start_ms %v must be inside observed_ms %v (observed runs from the first send)", *c0.StartMs, c0.ObservedMs)
	}
	if c0.ProcessList != nil {
		t.Fatalf("a lease-cold restart lists nothing (a new lease has no table): %+v", c0)
	}
	if c1.Restart || c1.RestartKind != "" || c1.StartMs != nil || c1.Execs != 1 || c1.Status != "ok" {
		t.Fatalf("the second call is warm: %+v", c1)
	}
}

func TestL2RestartKindServerLost(t *testing.T) {
	client, lr := newLeaseRelay(t)
	g := &guest{up: true, clientExit: func(run int, up bool) int32 {
		if run == 1 { // the second call finds the server gone (an OOM kill), the lease still live
			return 3
		}
		if up {
			return 0
		}
		return 3
	}}
	lr.execEnd = g.end
	lr.execEvents = startsOnFirst
	res, _, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_requery", "py_requery", "py_short")}, l2Lib(), client)
	if res.err != nil || len(res.calls) != 3 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	if c := res.calls[0]; c.Restart {
		t.Fatalf("the first call found a server: %+v", c)
	}
	c := res.calls[1]
	if !c.Restart || c.RestartKind != "server_lost" || c.Status != "ok" || c.Execs != 4 {
		t.Fatalf("server-lost restart: %+v", c)
	}
	if c.ProcessList == nil || !strings.Contains(*c.ProcessList, `"killed"`) {
		t.Fatalf("a server-lost restart records the process table before the start: %+v", c.ProcessList)
	}
	es := lr.execsOf("e15-t-0-0")
	if got := kinds(es[1:]); got[0] != pb.ExecKind_EXEC_KIND_COMMAND || got[1] != pb.ExecKind_EXEC_KIND_PROCESS_LIST || got[2] != pb.ExecKind_EXEC_KIND_PROCESS_START || got[3] != pb.ExecKind_EXEC_KIND_COMMAND {
		t.Fatalf("server-lost: client, list, start, client: %v", got)
	}
}

func TestL2SecondExit3FailsTheCall(t *testing.T) {
	for name, g := range map[string]*guest{"server never answers": {afterStart: true}, "start refused": {startFail: true}} {
		client, lr := newLeaseRelay(t)
		lr.execEnd = g.end
		lr.execEvents = startsOnFirst
		res, _, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_requery", "py_short", "py_short")}, l2Lib(), client)
		if res.err != nil || len(res.calls) != 3 {
			t.Fatalf("%s: err %v, %d calls", name, res.err, len(res.calls))
		}
		c := res.calls[0]
		if c.Status != "err" || c.Cause != causeL2Unavailable || !c.Restart || c.StartMs == nil {
			t.Fatalf("%s: %+v", name, c)
		}
		// client and start (refused); or client, start and the re-run: one start, never a second
		if (name == "start refused" && c.Execs != 2) || (name != "start refused" && c.Execs != 3) {
			t.Fatalf("%s: %d execs", name, c.Execs)
		}
	}
}

func TestL2Exits045NeverStartAServer(t *testing.T) {
	for _, code := range []int32{0, 4, 5} {
		client, lr := newLeaseRelay(t)
		g := &guest{up: true, clientExit: func(int, bool) int32 { return code }}
		lr.execEnd = g.end
		lr.execEvents = startsOnFirst
		res, _, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_requery", "py_requery", "py_requery")}, l2Lib(), client)
		if res.err != nil {
			t.Fatal(res.err)
		}
		for _, e := range lr.execsOf("e15-t-0-0") {
			if e.kind != pb.ExecKind_EXEC_KIND_COMMAND {
				t.Fatalf("exit %d: a process kind was sent: %v", code, e.kind)
			}
		}
		for _, c := range res.calls {
			if c.Restart || c.Execs != 1 {
				t.Fatalf("exit %d: %+v", code, c)
			}
			if code != 0 && (c.Cause != causeExitMismatch || c.FailedRC == nil || int32(*c.FailedRC) != code) {
				t.Fatalf("exit %d is the call's own failure: %+v", code, c)
			}
		}
	}
}

func TestL2NoProcessKindWithoutRestartFlag(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEnd = (&guest{}).end // no server: every client exits 3
	lr.execEvents = startsOnFirst
	res, _, _ := leaseRun(t, l2Cfg(false), []Session{sess("s", "u", 20, "py_requery", "py_short", "py_requery")}, l2Lib(), client)
	if res.err != nil || len(res.calls) != 3 {
		t.Fatalf("err %v, %d calls", res.err, len(res.calls))
	}
	for _, e := range lr.execsOf("e15-t-0-0") {
		if e.kind != pb.ExecKind_EXEC_KIND_COMMAND || e.process != nil {
			t.Fatalf("a process kind was sent without --l2-restart: %+v", e)
		}
	}
	if c := res.calls[0]; c.Restart || c.Cause != causeExitMismatch || c.FailedRC == nil || *c.FailedRC != 3 {
		t.Fatalf("without the rule an exit 3 is the call's failure: %+v", c)
	}
}

func TestL2ExitThreeOfAPlainCommandIsNotARestart(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEnd = func(_ string, _ int, e *pb.Exec) (int32, string, string) {
		return stepExitBase, "", "E15_FAILED_STEP=0 RC=3\n" // py_short's grep exits 3: not the level-2 client
	}
	lr.execEvents = startsOnFirst
	res, _, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_short", "py_short", "py_short")}, l2Lib(), client)
	if res.err != nil || len(res.calls) != 3 || res.calls[0].Restart || len(lr.execsOf("e15-t-0-0")) != 3 {
		t.Fatalf("err %v, calls %+v", res.err, res.calls)
	}
}

func TestProcessEventsAndTheLeaseTailTable(t *testing.T) {
	client, lr := newLeaseRelay(t)
	lr.execEnd = (&guest{up: true}).end
	tracked := []*pb.TrackedProcess{{Id: "1", Name: "l2srv", Pid: 42, State: "running", AgeMs: 1200, MemoryBytes: 500 << 20}}
	lr.execEvents = func(key string, n int) []*pb.LeaseEvent {
		switch n {
		case 0:
			return []*pb.LeaseEvent{startEvent(1000)}
		case 1: // the lease ended by idle with the server running, and a new one started
			return []*pb.LeaseEvent{{State: "end", Reason: "idle", AtUnixMs: 2000, Processes: []string{"l2srv (pid 42)"}, Tracked: tracked}, startEvent(3000)}
		}
		return nil
	}
	lr.statusFor = func(key string) (*pb.LeaseStatus, error) {
		return &pb.LeaseStatus{State: "active", Processes: tracked,
			Pending: &pb.LeaseEvent{State: "end", Reason: "idle", AtUnixMs: 4000, Processes: []string{"l2srv (pid 42)"}, Tracked: tracked}}, nil
	}
	res, tail, _ := leaseRun(t, l2Cfg(true), []Session{sess("s", "u", 20, "py_requery", "py_requery", "py_short")}, l2Lib(), client)
	if res.err != nil || len(res.calls) != 3 || len(tail) != 1 {
		t.Fatalf("err %v, %d calls, %d tail rows", res.err, len(res.calls), len(tail))
	}
	if pe := res.calls[0].ProcessEvents; pe != nil {
		t.Fatalf("an event without processes adds no process_events: %+v", pe)
	}
	pe := res.calls[1].ProcessEvents
	if len(pe) != 1 || pe[0].State != "end" || pe[0].Reason != "idle" || pe[0].AtUnixMs != 2000 ||
		len(pe[0].Processes) != 1 || pe[0].Processes[0] != "l2srv (pid 42)" ||
		len(pe[0].Tracked) != 1 || pe[0].Tracked[0].Name != "l2srv" || pe[0].Tracked[0].State != "running" || pe[0].Tracked[0].MemoryBytes != 500<<20 {
		t.Fatalf("process_events %+v", pe)
	}
	if le := res.calls[1].LeaseEvents; len(le) != 2 || le[0].State != "end" {
		t.Fatalf("lease_events keep their E17b shape beside it: %+v", le)
	}
	row := tail[0]
	if len(row.Processes) != 1 || row.Processes[0].Pid != 42 || row.Processes[0].AgeMs != 1200 {
		t.Fatalf("lease-tail processes %+v", row.Processes)
	}
	if len(row.PendingProcesses) != 1 || len(row.PendingTracked) != 1 || row.PendingTracked[0].Name != "l2srv" {
		t.Fatalf("lease-tail pending's processes %+v / %+v", row.PendingProcesses, row.PendingTracked)
	}
}
