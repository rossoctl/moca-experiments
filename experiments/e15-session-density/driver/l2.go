package main

// E17d's level-2 restart rule (PLAN-E17D Task 4, spec §14.2), on with --l2-restart (lease+processes only).
//
// At ship-300-l2 a py_requery or py_refit call runs the level-2 client, `cd project && ../venv/bin/python l2c.py
// <query>`, which probes the server (connect and ping, 2 s) before its query. Its exit 3 means the probe found no
// server, and only that: a slow live server answers the probe and exits 0, 4 or 5, and those are never restarts. On
// exit 3 the driver starts the server as a tracked process (process_start: command l2ServerCmd, cwd l2ServerCwd, name
// l2ServerName) and re-runs the call's plan with the client's --wait 60, so the client waits for the server's pong.
// The call is then a restart: its observed time runs from the first send and includes the start; start_ms is the
// start's own time. restart_kind is lease_cold when the call's first Exec started a new lease (the session's first
// call, or a lease that ended since the last one), else server_lost (the lease was live but its server did not
// answer: an OOM kill or a crash); a server-lost restart sends process_list first and keeps the table it answers
// (process_list), since the start would drop the exited entry. A second exit 3, or a start that fails, fails the call
// with cause l2_server_unavailable. Without --l2-restart no process kind is ever sent.

import (
	"context"
	"strconv"
	"strings"
	"time"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const (
	l2ServerCmd        = "../venv/bin/python l2srv.py"
	l2ServerCwd        = "/workspace/project"
	l2ServerName       = "l2srv"
	l2ClientProgram    = "l2c.py"
	l2NoServerExit     = 3 // l2c.py's exit when its probe found no server
	l2WaitS            = 60
	l2ProcessTimeoutS  = 60 // timeout_s of a process_start or process_list
	causeL2Unavailable = "l2_server_unavailable"
	restartLeaseCold   = "lease_cold"
	restartServerLost  = "server_lost"
)

// l2Restart reports whether res (the first Exec of a call planned as plan) is the level-2 client's exit 3: the
// joined script's failing step runs l2c.py and that step itself exited 3.
func l2Restart(plan []Planned, res execResult) bool {
	if res.cause != "" || res.exit == nil || *res.exit == 0 {
		return false
	}
	k, rc, ok := failedFromExit(*res.exit, res.stderr)
	return ok && rc != nil && *rc == l2NoServerExit && k < len(plan) && strings.Contains(plan[k].Cmd, l2ClientProgram)
}

// l2WaitPlan is plan with --wait 60 on every client step: the re-run after a start.
func l2WaitPlan(plan []Planned) []Planned {
	out := make([]Planned, len(plan))
	for i, p := range plan {
		if strings.Contains(p.Cmd, l2ClientProgram) {
			p.Cmd += " --wait " + strconv.Itoa(l2WaitS)
		}
		out[i] = p
	}
	return out
}

// execProcess sends one process kind on key (with the session's lease bearer): process_start of the server, or
// process_list. kind PROCESS_START carries l2ServerCmd and its ProcessArgs; PROCESS_LIST no command.
func (r *Replayer) execProcess(ctx context.Context, ls *leaseSession, key string, kind pb.ExecKind) (execResult, error) {
	cctx, err := ls.bearerFor(ctx, l2ProcessTimeoutS)
	if err != nil {
		return execResult{}, err
	}
	ex := &pb.Exec{ReqId: r.reqID.Add(1), TimeoutS: l2ProcessTimeoutS, WorkspaceKey: key, Kind: kind}
	if kind == pb.ExecKind_EXEC_KIND_PROCESS_START {
		ex.Command = l2ServerCmd
		ex.Process = &pb.ProcessArgs{Name: l2ServerName, Cwd: l2ServerCwd}
	}
	return execReq(cctx, r.client, r.cfg.SandboxID, ex, true), nil
}

// l2Outcome is what the restart did, for the call's record.
type l2Outcome struct {
	kind     string
	startMs  float64
	list     *string
	execs    int    // Execs sent by the restart (list, start, re-run)
	failMsg  string // non-empty: the call fails with causeL2Unavailable
	plan     []Planned
	events   []leaseEvent // every Exec's events, in order (the first one's included)
	final    execResult   // the re-run's result (when it ran)
	finalRan bool
}

// l2RestartCall runs the restart after first (the call's first Exec, exit 3) and returns its outcome.
func (r *Replayer) l2RestartCall(ctx context.Context, ls *leaseSession, key, class string, plan []Planned, first execResult, timeoutS uint32, keep bool) l2Outcome {
	o := l2Outcome{kind: restartServerLost, plan: plan, events: append([]leaseEvent(nil), first.events...)}
	if hasStart(first.events) {
		o.kind = restartLeaseCold
	}
	if o.kind == restartServerLost {
		if lst, err := r.execProcess(ctx, ls, key, pb.ExecKind_EXEC_KIND_PROCESS_LIST); err == nil {
			o.execs++
			o.events = append(o.events, lst.events...)
			out := string(cutRunes(lst.stdout))
			o.list = &out
		}
	}
	t0 := time.Now()
	st, err := r.execProcess(ctx, ls, key, pb.ExecKind_EXEC_KIND_PROCESS_START)
	o.startMs = ms(time.Since(t0))
	if err != nil {
		o.failMsg = "process_start: minting the exec token: " + err.Error()
		return o
	}
	o.execs++
	o.events = append(o.events, st.events...)
	switch {
	case st.cause != "":
		o.failMsg = "process_start: " + st.cause + ": " + st.msg
		return o
	case *st.exit != 0:
		o.failMsg = "process_start: exit " + strconv.Itoa(int(*st.exit)) + ": " + strings.TrimSpace(string(st.stderr))
		return o
	}
	o.plan = l2WaitPlan(plan)
	script, err := JoinPlanScan(o.plan, o.plan[len(o.plan)-1].SleepAfterMs, r.cfg.Scan.For(class))
	if err != nil {
		o.failMsg = "joining the re-run: " + err.Error()
		return o
	}
	rctx, err := ls.bearerFor(ctx, timeoutS+l2WaitS)
	if err != nil {
		o.failMsg = "re-run: minting the exec token: " + err.Error()
		return o
	}
	o.final = execOne(rctx, r.client, r.cfg.SandboxID, r.reqID.Add(1), script, timeoutS+l2WaitS, key, keep)
	o.execs++
	o.finalRan = true
	o.events = append(o.events, o.final.events...)
	if l2Restart(o.plan, o.final) {
		o.failMsg = "the client still found no server after the start (exit 3 with --wait " + strconv.Itoa(l2WaitS) + ")"
	}
	return o
}
