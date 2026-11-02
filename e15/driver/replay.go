package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc/metadata"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

// Config is one rung's replay parameters.
type Config struct {
	N       int
	Seed    int64
	UserCap float64       // SPEC §5.7: max fraction of the live population one user may hold
	Warmup  time.Duration // not measured
	Window  time.Duration // measured; the run ends at Warmup+Window
	Spread  time.Duration // the N slots' first sessions start evenly over this span
	Grace   time.Duration // after the run's end, Execs still in flight are cancelled at end+Grace
	// EndSessionExec sends one EndSessionCommand Exec on a session's workspace_key when the session
	// ends (its trace is done, or the run ended with it live), so the resident worker frees its VM.
	EndSessionExec bool
	SandboxID      string
	RunID          string
	Token          string
}

// Replayer holds a population of N sessions, closed-loop inside each session (SPEC §3).
type Replayer struct {
	cfg    Config
	lib    *Library
	client pb.SandboxExecClient
	rec    *Recorder

	mu        sync.Mutex // guards sampler, liveUsers, liveCount
	sampler   *Sampler
	liveUsers map[string]int
	liveCount int

	reqID atomic.Uint64

	endCtx                    context.Context // bearer, not bounded by the grace deadline
	endSent, endOK, endFailed atomic.Int64

	t0, warmEnd, end, graceEnd time.Time
}

func NewReplayer(cfg Config, sessions []Session, lib *Library, client pb.SandboxExecClient, rec *Recorder) (*Replayer, error) {
	if cfg.N < 1 {
		return nil, fmt.Errorf("n must be >= 1, got %d", cfg.N)
	}
	if cfg.Window <= 0 || cfg.Warmup < 0 || cfg.Spread < 0 || cfg.Grace < 0 {
		return nil, fmt.Errorf("window must be > 0 and warmup, spread, grace >= 0 (got %v, %v, %v, %v)", cfg.Window, cfg.Warmup, cfg.Spread, cfg.Grace)
	}
	if cfg.Token == "" {
		return nil, fmt.Errorf("no exec token: set MOCA_RELAY_EXEC_TOKEN to the relay's worker credential; the relay refuses SandboxExec without it")
	}
	s, err := NewSampler(sessions, cfg.Seed, cfg.UserCap)
	if err != nil {
		return nil, err
	}
	if err := validatePlans(sessions, lib, cfg.Seed); err != nil {
		return nil, err
	}
	r := &Replayer{cfg: cfg, lib: lib, client: client, rec: rec, sampler: s, liveUsers: map[string]int{}}
	// req_id is the relay's correlation key: a random salt in the high bits keeps two driver
	// processes (or a restarted one) from colliding, a counter makes ids unique within one. The
	// relay decodes req_id into a JS number and refuses anything above 2^53-1, so the id is a
	// 21-bit salt over a 32-bit counter (moca's harness scheme, session/cache.go): 53 bits.
	var salt [4]byte
	if _, err := rand.Read(salt[:]); err != nil {
		return nil, err
	}
	r.reqID.Store(uint64(binary.BigEndian.Uint32(salt[:])&reqIDSaltMask) << 32)
	return r, nil
}

// maxJoinedBytes bounds a joined script: the guest agent's protocol caps a frame at 32 KiB
// (MaxFrame, remote-worker/internal/guestagent/protocol.go, moca v0.9.0), and a larger Exec never
// completes, running into its timeout. 30 KiB leaves room for the frame's other fields.
const maxJoinedBytes = 30 << 10

// validatePlans plans and joins every call of every replayable session once, so a library that
// cannot expand some call, or expands it into a script over maxJoinedBytes, fails the run before
// it starts rather than mid-window.
func validatePlans(sessions []Session, lib *Library, seed int64) error {
	over, largest := 0, 0
	var where string
	for _, s := range sessions {
		if len(s.Calls) < minCalls {
			continue // the sampler never draws it
		}
		for _, c := range s.Calls {
			p, err := lib.Plan(c, seed, s.ID)
			if err != nil {
				return fmt.Errorf("planning %s call %d: %w", s.ID, c.I, err)
			}
			if len(p) == 0 {
				return fmt.Errorf("planning %s call %d: no commands", s.ID, c.I)
			}
			script, err := JoinPlan(p, p[len(p)-1].SleepAfterMs)
			if err != nil {
				return fmt.Errorf("joining %s call %d: %w", s.ID, c.I, err)
			}
			if len(script) > maxJoinedBytes {
				over++
				if len(script) > largest {
					largest, where = len(script), fmt.Sprintf("%s call %d, class %s, %d steps", s.ID, c.I, c.Class, len(p))
				}
			}
		}
	}
	if over > 0 {
		return fmt.Errorf("%d call(s) join into a script over the guest frame limit of %d bytes; the largest is %d bytes (%s)",
			over, maxJoinedBytes, largest, where)
	}
	return nil
}

// Live is the number of sessions currently live (started and not finished).
func (r *Replayer) Live() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.liveCount
}

// swap ends prev (if non-nil) and draws its replacement in one critical section, so the live
// count never dips between a session's end and its successor's start.
func (r *Replayer) swap(prev *Session) (Session, int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if prev != nil {
		r.liveUsers[prev.User]--
		r.liveCount--
	}
	s, start, err := r.sampler.Next(r.liveUsers, r.cfg.N)
	if err != nil {
		return Session{}, 0, err
	}
	r.liveUsers[s.User]++
	r.liveCount++
	return s, start, nil
}

func (r *Replayer) release(s Session) {
	r.mu.Lock()
	r.liveUsers[s.User]--
	r.liveCount--
	r.mu.Unlock()
}

// sleepUntil sleeps until t, returning false if the run's end comes first (t >= end) or ctx is
// done. A t in the past returns at once: no sleep is ever negative.
func (r *Replayer) sleepUntil(ctx context.Context, t time.Time) bool {
	if !t.Before(r.end) {
		d := time.Until(r.end)
		if d > 0 {
			select {
			case <-ctx.Done():
			case <-time.After(d):
			}
		}
		return false
	}
	d := time.Until(t)
	if d <= 0 {
		return ctx.Err() == nil
	}
	tm := time.NewTimer(d)
	defer tm.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-tm.C:
		return true
	}
}

// Run replays until Warmup+Window has elapsed: in-flight calls finish and are recorded, no new
// call starts. It returns an error only for a run-fatal condition (ErrCapUnsatisfiable, a plan
// error, ctx cancelled); per-call failures are recorded, never returned.
func (r *Replayer) Run(ctx context.Context) error {
	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+r.cfg.Token)
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)

	r.t0 = time.Now()
	r.warmEnd = r.t0.Add(r.cfg.Warmup)
	r.end = r.warmEnd.Add(r.cfg.Window)
	r.graceEnd = r.end.Add(r.cfg.Grace)
	// Every Exec runs under execCtx: one still in flight at end+Grace is cancelled, recorded as
	// cause "cut_at_end" when its planned completion is after end+Grace, else "deadline"; one that
	// would start after it fails at once as "deadline" with execs 0.
	execCtx, cancelExec := context.WithDeadline(ctx, r.graceEnd)
	defer cancelExec()
	// End-session Execs outlive the grace deadline and a SIGINT: a session live at the end still
	// frees its VM. Each is bounded by its own TimeoutS plus execOne's slack.
	r.endCtx = context.WithoutCancel(ctx)

	cpuDone := make(chan struct{})
	cpuStop := make(chan struct{})
	go func() { defer close(cpuDone); r.sampleCPU(cpuStop) }()

	var wg sync.WaitGroup
	for slot := 0; slot < r.cfg.N; slot++ {
		var at time.Duration
		if r.cfg.N > 1 {
			at = r.cfg.Spread * time.Duration(slot) / time.Duration(r.cfg.N-1)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.runSlot(execCtx, slot, r.t0.Add(at)); err != nil {
				cancel(err)
			}
		}()
	}
	wg.Wait()
	close(cpuStop)
	<-cpuDone
	if r.cfg.EndSessionExec {
		r.rec.CPUFooter(cpuFooter{Footer: true, EndSessionsSent: r.endSent.Load(), EndSessionsOK: r.endOK.Load(), EndSessionsFailed: r.endFailed.Load()})
	}
	if err := context.Cause(ctx); err != nil {
		return err
	}
	return nil
}

func (r *Replayer) runSlot(ctx context.Context, slot int, startAt time.Time) error {
	if !r.sleepUntil(ctx, startAt) {
		return nil
	}
	var prev *Session
	for seq := 0; ; seq++ {
		if ctx.Err() != nil || !time.Now().Before(r.end) {
			if prev != nil {
				r.release(*prev)
			}
			return nil
		}
		s, start, err := r.swap(prev)
		if err != nil {
			return fmt.Errorf("slot %d: drawing session %d: %w", slot, seq, err)
		}
		prev = &s
		key := "e15-" + r.cfg.RunID + "-" + strconv.Itoa(slot) + "-" + strconv.Itoa(seq)
		err = r.runSession(ctx, key, s, start)
		// Before the slot draws its next session, so the worker frees this VM before the next
		// session acquires one. Sent however the session ended.
		r.endSession(key)
		if err != nil {
			r.release(s)
			return err
		}
	}
}

// reqIDSaltMask keeps req_id within 2^53-1 (21 salt bits over a 32-bit counter).
const reqIDSaltMask = 1<<21 - 1

// EndSessionCommand is the resident worker's end-of-session marker (Task 5).
const (
	EndSessionCommand  = ": e15-end-session"
	endSessionTimeoutS = 60
)

// endSession sends the end-session Exec on key when EndSessionExec is on. It is counted in the
// driver-cpu.jsonl footer and never recorded as a call.
func (r *Replayer) endSession(key string) {
	if !r.cfg.EndSessionExec {
		return
	}
	r.endSent.Add(1)
	res := execOne(r.endCtx, r.client, r.cfg.SandboxID, r.reqID.Add(1), EndSessionCommand, endSessionTimeoutS, key)
	if res.cause == "" && *res.exit == 0 {
		r.endOK.Add(1)
	} else {
		r.endFailed.Add(1)
	}
}

// runSession replays s from call index start to the end of its trace (or the run's end).
func (r *Replayer) runSession(ctx context.Context, key string, s Session, start int) error {
	var (
		prevEmit         time.Time
		wCalls           int
		wPlanned         int64
		wLastGap         int64
		wFirst, wLastEnd time.Time
	)
	defer func() {
		if wCalls > 0 {
			r.rec.Session(sessionRecord{
				Session: key, Trace: s.ID, Provider: s.Provider, WindowCalls: wCalls,
				// The last call's gap is after its End, where observed_ms stops, so it is not
				// planned time for the window. A chain's idle tail runs inside its Exec, before
				// End, so it is.
				PlannedMs:  wPlanned - wLastGap,
				ObservedMs: ms(wLastEnd.Sub(wFirst)),
			})
		}
	}()
	for idx := start; idx < len(s.Calls); idx++ {
		c := s.Calls[idx]
		plan, err := r.lib.Plan(c, r.cfg.Seed, s.ID)
		if err != nil { // validatePlans makes this unreachable for a corpus it checked
			return fmt.Errorf("planning %s call %d: %w", s.ID, c.I, err)
		}
		if !prevEmit.IsZero() {
			// max(0, offset - elapsed since the previous emit), via sleepUntil.
			if !r.sleepUntil(ctx, prevEmit.Add(time.Duration(c.OffsetMs)*time.Millisecond)) {
				return nil
			}
		}
		send := time.Now()
		if !send.Before(r.end) || ctx.Err() != nil {
			return nil
		}
		prevEmit = send
		rec, last := r.runCall(ctx, key, s, c, plan, send)
		r.rec.Call(rec)
		// A call cut at the end of the run never completed, so it is not part of the session's
		// pace (SPEC §8 condition 3: first to last completed call).
		if rec.InWindow && rec.Cause != causeCutAtEnd {
			if wCalls == 0 {
				wFirst = send
			}
			wCalls++
			wPlanned += c.DurMs + c.GapMs
			wLastGap = c.GapMs
			wLastEnd = last
		}
		if ctx.Err() != nil {
			return nil
		}
	}
	return nil
}

// runCall sends one recorded call as ONE Exec on key: its planned invocations joined into one
// guest script (JoinPlan), the chain idle tail as the script's final sleep, so the sandbox is held
// for the call's whole recorded lifetime (SPEC §5.3) and SBX pays one VM per recorded call, as the
// real agent did. It returns the call's record and the time its Exec ended.
func (r *Replayer) runCall(ctx context.Context, key string, s Session, c Call, plan []Planned, send time.Time) (callRecord, time.Time) {
	timeoutS := uint32((c.DurMs+999)/1000) + 120
	rec := callRecord{
		Ts: send.UTC().Format(time.RFC3339Nano), TMs: ms(send.Sub(r.t0)),
		Session: key, Trace: s.ID, Provider: s.Provider, Call: c.I, Class: c.Class,
		PlannedDurMs: c.DurMs, PlannedGapMs: c.GapMs,
		Status: "ok", Cause: causeOK,
		InWindow: !send.Before(r.warmEnd) && send.Before(r.end),
	}
	script, err := JoinPlan(plan, plan[len(plan)-1].SleepAfterMs)
	if err != nil { // validatePlans makes this unreachable for a corpus it checked
		rec.Status, rec.Cause, rec.Msg = "err", causeExecError, err.Error()
		return rec, time.Now()
	}
	if !time.Now().Before(r.graceEnd) {
		rec.Status, rec.Cause, rec.Msg = "err", causeDeadline, "not started: past the end-of-run grace deadline"
		return rec, time.Now()
	}
	res := execOne(ctx, r.client, r.cfg.SandboxID, r.reqID.Add(1), script, timeoutS, key)
	last := time.Now()
	rec.Execs = 1
	rec.Exit = res.exit
	switch {
	case res.cause == "" && *res.exit != 0:
		res.cause = causeExitMismatch
		if k, rc, ok := failedFromExit(*res.exit, res.stderr); ok && k < len(plan) {
			rec.FailedStep, rec.FailedRC = &k, rc
			got := "?"
			if rc != nil {
				got = strconv.Itoa(*rc)
			}
			res.msg = fmt.Sprintf("exit %d: step %d exited %s, expected %d: %s", *res.exit, k, got, plan[k].Exit, plan[k].Cmd)
		} else {
			res.msg = fmt.Sprintf("exit %d, expected 0 from the joined script", *res.exit)
		}
	case res.cause == causeDeadline && errors.Is(ctx.Err(), context.DeadlineExceeded) &&
		send.Add(time.Duration(c.DurMs)*time.Millisecond).After(r.graceEnd):
		// Cancelled at the grace deadline while it was still within its planned lifetime: the
		// run's end cut it, the backend did not fail it.
		res.cause = causeCutAtEnd
		res.msg = "cut at the end-of-run grace deadline before its planned completion"
	}
	if res.cause != "" {
		rec.Status, rec.Cause, rec.Msg = "err", res.cause, res.msg
	}
	rec.ObservedMs = ms(last.Sub(send))
	return rec, last
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// sampleCPU writes the driver's cumulative CPU at 1 Hz from the run's start, plus one final
// sample when stop closes.
func (r *Replayer) sampleCPU(stop <-chan struct{}) {
	sample := func() {
		u, s, err := selfCPU()
		r.rec.keep(err)
		if err == nil {
			r.rec.CPU(cpuRecord{T: time.Since(r.t0).Seconds(), UtimeMs: u, StimeMs: s})
		}
	}
	r.rec.CPUHeader(cpuHeader{Header: true, NumCPU: runtime.NumCPU(), GOMAXPROCS: runtime.GOMAXPROCS(0), GOOS: runtime.GOOS, GOARCH: runtime.GOARCH, T0Epoch: float64(r.t0.UnixNano()) / 1e9})
	sample()
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	for {
		select {
		case <-stop:
			sample()
			return
		case <-tk.C:
			sample()
		}
	}
}
