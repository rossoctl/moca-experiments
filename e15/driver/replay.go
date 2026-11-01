package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
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
	N         int
	Seed      int64
	UserCap   float64       // SPEC §5.7: max fraction of the live population one user may hold
	Warmup    time.Duration // not measured
	Window    time.Duration // measured; the run ends at Warmup+Window
	Spread    time.Duration // the N slots' first sessions start evenly over this span
	Grace     time.Duration // after the run's end, Execs still in flight are cancelled at end+Grace
	SandboxID string
	RunID     string
	Token     string
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
	// req_id is the relay's correlation key: a random 32-bit salt in the high half keeps two
	// driver processes (or a restarted one) from colliding, a counter makes ids unique within one.
	var salt [4]byte
	if _, err := rand.Read(salt[:]); err != nil {
		return nil, err
	}
	r.reqID.Store(uint64(binary.BigEndian.Uint32(salt[:])) << 32)
	return r, nil
}

// validatePlans plans every call of every replayable session once, so a library that cannot
// expand some call fails the run before it starts rather than aborting it mid-window.
func validatePlans(sessions []Session, lib *Library, seed int64) error {
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
		}
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
	// Every Exec runs under execCtx: one still in flight at end+Grace is cancelled, and one that
	// would start after it fails at once, both recorded as cause "deadline".
	execCtx, cancelExec := context.WithDeadline(ctx, r.graceEnd)
	defer cancelExec()

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
		if err := r.runSession(ctx, key, s, start); err != nil {
			r.release(s)
			return err
		}
	}
}

// runSession replays s from call index start to the end of its trace (or the run's end).
func (r *Replayer) runSession(ctx context.Context, key string, s Session, start int) error {
	var (
		prevEmit          time.Time
		wCalls            int
		wPlanned          int64
		wLastGap, wLastTl int64
		wFirst, wLastEnd  time.Time
	)
	defer func() {
		if wCalls > 0 {
			r.rec.Session(sessionRecord{
				Session: key, Trace: s.ID, Provider: s.Provider, WindowCalls: wCalls,
				// The last call's gap and chain idle tail are both after its End, where
				// observed_ms stops, so neither is planned time for the window.
				PlannedMs:  wPlanned - wLastGap - wLastTl,
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
		tail := plan[len(plan)-1].SleepAfterMs
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
		rec.TailMs = tail
		r.rec.Call(rec)
		if rec.InWindow {
			if wCalls == 0 {
				wFirst = send
			}
			wCalls++
			wPlanned += c.DurMs + c.GapMs
			wLastGap, wLastTl = c.GapMs, tail
			wLastEnd = last
		}
		if ctx.Err() != nil {
			return nil
		}
		// A chain call's idle tail is part of its recorded lifetime; slept whatever the outcome so
		// a failing backend does not also compress the session's timeline.
		if tail > 0 {
			if !r.sleepUntil(ctx, last.Add(time.Duration(tail)*time.Millisecond)) {
				return nil
			}
		}
	}
	return nil
}

// runCall sends one recorded call's planned Execs in order on key and returns its record and the
// time its last Exec ended. The call stops at its first failing Exec.
func (r *Replayer) runCall(ctx context.Context, key string, s Session, c Call, plan []Planned, send time.Time) (callRecord, time.Time) {
	timeoutS := uint32((c.DurMs+999)/1000) + 120
	rec := callRecord{
		Ts: send.UTC().Format(time.RFC3339Nano), TMs: ms(send.Sub(r.t0)),
		Session: key, Trace: s.ID, Provider: s.Provider, Call: c.I, Class: c.Class,
		PlannedDurMs: c.DurMs, PlannedGapMs: c.GapMs,
		Status: "ok", Cause: causeOK,
		InWindow: !send.Before(r.warmEnd) && send.Before(r.end),
	}
	var last time.Time
	for _, p := range plan {
		if !time.Now().Before(r.graceEnd) {
			// Past the grace deadline: do not start the rest of this call.
			last = time.Now()
			rec.Exit, rec.ExpectedExit = nil, p.Exit
			rec.Status, rec.Cause, rec.Msg = "err", causeDeadline, "not started: past the end-of-run grace deadline"
			break
		}
		res := execOne(ctx, r.client, r.cfg.SandboxID, r.reqID.Add(1), p.Cmd, timeoutS, key)
		last = time.Now()
		rec.Execs++
		rec.Exit, rec.ExpectedExit = res.exit, p.Exit
		if res.cause == "" && *res.exit != p.Exit {
			res.cause = causeExitMismatch
			res.msg = fmt.Sprintf("exit %d, expected %d: %s", *res.exit, p.Exit, p.Cmd)
		}
		if res.cause != "" {
			rec.Status, rec.Cause, rec.Msg = "err", res.cause, res.msg
			break
		}
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
	r.rec.CPUHeader(cpuHeader{Header: true, NumCPU: runtime.NumCPU(), GOMAXPROCS: runtime.GOMAXPROCS(0), GOOS: runtime.GOOS, GOARCH: runtime.GOARCH})
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
