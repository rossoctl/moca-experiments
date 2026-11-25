package main

// Lease mode (E17b), opt-in with --lease-mode. Each session (workspace key K) is its own sandbox
// as far as the relay's sandbox path is concerned: sbx = wsk = K, wrk = the worker's SANDBOX_ID.
// Before the session's first Exec the driver sends LeaseControl set_mode (epoch 1) and waits for
// the acknowledgement: until then the worker runs a new workspace per-Exec and the Exec would
// silently measure the wrong arm. The rules the relay applies are in moca's
// packages/sandbox-relay/src/sandbox-caller.ts (sandboxLeaseControl): the call's bearer is the
// sandbox token of K, sandbox_id must equal its wrk, and a set_mode also carries a set-mode token
// for the same sbx/wrk/wsk in the request body.

import (
	"context"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc/metadata"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const (
	leaseModeEpoch    = 1                 // the epoch of the set_mode every session sends, and of its Exec tokens
	leaseModeName     = "lease"           // the JWT mode claim's default (E17b, E17c: level 1)
	leaseModeL2       = "lease+processes" // E17d's level-2 arm (--lease-mode=lease+processes)
	leaseSub          = "e15-driver"
	leaseTenant       = "e15"
	leaseDefaultTTL   = 300 * time.Second // base Exec token TTL, refreshed before it runs out; a longer call gets a longer one (E17B-R34)
	setModeCallLimit  = 120 * time.Second // client-side bound on one set_mode
	statusCallLimit   = 30 * time.Second  // client-side bound on one status call of the sweep
	resetCallLimit    = 120 * time.Second // client-side bound on one reset (ownwalk; the lease is idle)
	sweepParallel     = 32
	setModeFailBackof = time.Second // a session whose set_mode failed waits this long before the slot draws the next
	causeSetMode      = "set_mode_failed"
)

// LeaseConfig turns lease mode on (Config.Lease != nil).
type LeaseConfig struct {
	Key          TokenKey
	Iss          string // must equal the relay's SH_SANDBOX_TOKEN_ISSUER; no default
	Wrk          string // the worker's SANDBOX_ID; equals every ExecRequest.sandbox_id
	IdleTimeoutS int
	TokenTTL     time.Duration // Exec token TTL; 0 = 300 s
	// Mode is the JWT mode claim of every Exec token and of the set-mode token (E17d, --lease-mode=MODE): "lease"
	// (level 1) or "lease+processes" (level 2). "" is "lease", so E17b and E17c's rungs are unchanged.
	Mode string
	// L2Restart (E17d, --l2-restart; Mode lease+processes only): the level-2 restart rule (l2.go).
	L2Restart bool
}

func (c *LeaseConfig) mode() string {
	if c.Mode == "" {
		return leaseModeName
	}
	return c.Mode
}

func (c *LeaseConfig) ttl() time.Duration {
	if c.TokenTTL > 0 {
		return c.TokenTTL
	}
	return leaseDefaultTTL
}

// leaseModeFlag is --lease-mode: a boolean switch as E17b and E17c's rung.sh passes it (bare --lease-mode is "lease"),
// that also takes the mode claim as --lease-mode=MODE (E17d: "lease" or "lease+processes"). The value must be joined
// with "=": "--lease-mode lease+processes" would leave the mode as a positional argument, which realMain refuses.
type leaseModeFlag struct{ mode string }

func (f *leaseModeFlag) IsBoolFlag() bool { return true }
func (f *leaseModeFlag) String() string   { return f.mode }
func (f *leaseModeFlag) Set(v string) error {
	switch v {
	case "true", leaseModeName:
		f.mode = leaseModeName
	case leaseModeL2:
		f.mode = leaseModeL2
	default:
		return fmt.Errorf("want bare --lease-mode (lease), --lease-mode=lease or --lease-mode=lease+processes, got %q", v)
	}
	return nil
}

// LoadTokenKey reads an Ed25519 private key from a PKCS#8 PEM file (openssl genpkey -algorithm ed25519).
func LoadTokenKey(path string) (TokenKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return TokenKey{}, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return TokenKey{}, fmt.Errorf("%s: no PEM block", path)
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return TokenKey{}, fmt.Errorf("%s: %w", path, err)
	}
	priv, ok := k.(ed25519.PrivateKey)
	if !ok {
		return TokenKey{}, fmt.Errorf("%s: not an Ed25519 key (%T)", path, k)
	}
	return TokenKey{Priv: priv}, nil
}

// leaseEvent is one LeaseEvent as calls.jsonl and lease-tail.jsonl record it.
type leaseEvent struct {
	State    string `json:"state"`
	Reason   string `json:"reason"`
	AtUnixMs int64  `json:"at_unix_ms"`
	AgeMs    uint64 `json:"age_ms"`
	Mode     string `json:"mode"`
	// E17d: the processes the event names (moca's display strings and the structured form), nil when it names none.
	// Unexported (and a pointer, so the struct stays comparable), so lease_events keeps its E17b shape; the call's
	// process_events carries them (processEventsOf).
	procs *processEvent
}

// trackedProc is one moca TrackedProcess as calls.jsonl and lease-tail.jsonl record it (E17d).
type trackedProc struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Pid         uint32 `json:"pid"`
	State       string `json:"state"`
	Code        int32  `json:"code"`
	AgeMs       uint64 `json:"age_ms"`
	MemoryBytes uint64 `json:"memory_bytes"`
}

func trackedOf(ps []*pb.TrackedProcess) []trackedProc {
	var out []trackedProc
	for _, p := range ps {
		out = append(out, trackedProc{ID: p.GetId(), Name: p.GetName(), Pid: p.GetPid(), State: p.GetState(), Code: p.GetCode(), AgeMs: p.GetAgeMs(), MemoryBytes: p.GetMemoryBytes()})
	}
	return out
}

// processEvent is one process_events entry (E17d): a lease event that named processes, with what it named.
type processEvent struct {
	State     string        `json:"state"`
	Reason    string        `json:"reason"`
	AtUnixMs  int64         `json:"at_unix_ms"`
	Processes []string      `json:"processes"`
	Tracked   []trackedProc `json:"tracked"`
}

// processEventsOf is every event of evs that named a process (processes or tracked), nil when none.
func processEventsOf(evs []leaseEvent) []processEvent {
	var out []processEvent
	for _, e := range evs {
		if e.procs != nil {
			out = append(out, *e.procs)
		}
	}
	return out
}

func modeName(m pb.SandboxMode) string {
	switch m {
	case pb.SandboxMode_SANDBOX_MODE_LEASE:
		return "lease"
	case pb.SandboxMode_SANDBOX_MODE_LEASE_PROCESSES:
		return "lease+processes"
	default: // UNSPECIFIED is per-exec
		return "per-exec"
	}
}

func eventOf(e *pb.LeaseEvent) leaseEvent {
	ev := leaseEvent{State: e.GetState(), Reason: e.GetReason(), AtUnixMs: e.GetAtUnixMs(), AgeMs: e.GetAgeMs(), Mode: modeName(e.GetMode())}
	if len(e.GetProcesses()) > 0 || len(e.GetTracked()) > 0 {
		ev.procs = &processEvent{State: ev.State, Reason: ev.Reason, AtUnixMs: ev.AtUnixMs, Processes: e.GetProcesses(), Tracked: trackedOf(e.GetTracked())}
	}
	return ev
}

// leaseTailRow is one lease-tail.jsonl line: the end-of-run status of one session's workspace.
// A status call that failed is {key, error}. state is none | active | expiring; pending is the
// last undelivered event, and a lease still live at the sweep is the matcher's live_at_stop.
// swept_at_unix_ms is the wall time the row's status call was sent (E17B-R31): a live lease's end
// line at or after it is the matcher's ended_after_sweep, not an unmatched end.
type leaseTailRow struct {
	Key           string      `json:"key"`
	State         string      `json:"state,omitempty"`
	Pending       *leaseEvent `json:"pending,omitempty"`
	Error         string      `json:"error,omitempty"`
	SweptAtUnixMs int64       `json:"swept_at_unix_ms"`
	// E17d (omitted when empty, so E17b and E17c rows are unchanged): the status's tracked-process table (a live
	// lease's, exited entries included), and the processes the pending event names.
	Processes        []trackedProc `json:"processes,omitempty"`
	PendingProcesses []string      `json:"pending_processes,omitempty"`
	PendingTracked   []trackedProc `json:"pending_tracked,omitempty"`
}

// leaseSession is one session's lease state. Its methods are called from the session's own
// goroutine, one call at a time (the sweep runs after every session has ended).
type leaseSession struct {
	key      string
	cfg      *LeaseConfig
	ref      *Refresher
	seen     map[[2]any]bool // (at_unix_ms, state) of every event already recorded
	checked  bool            // the session's first call that ran an Exec has been judged (E17B-R30)
	notLease bool            // that call carried no start event
	// configRefused is the first configuration refusal the session saw (configRefusal; E17B-R42), "" when none.
	configRefused string
}

func newLeaseSession(cfg *LeaseConfig, key string) *leaseSession {
	// The epoch is fixed when the Refresher is built: it is the epoch of the set_mode this
	// session sends and the worker acknowledges.
	ref := NewRefresher(cfg.Key, SandboxClaims{
		Iss: cfg.Iss, Sub: leaseSub, Tenant: leaseTenant, Sbx: key, Wrk: cfg.Wrk,
		Mode: cfg.mode(), ModeEpoch: leaseModeEpoch, IdleTimeoutS: cfg.IdleTimeoutS, TTL: cfg.ttl(),
	}, nil)
	return &leaseSession{key: key, cfg: cfg, ref: ref, seen: map[[2]any]bool{}}
}

// bearer returns ctx carrying a current Exec token of this session.
func (l *leaseSession) bearer(ctx context.Context) (context.Context, error) {
	tok, err := l.ref.Token()
	if err != nil {
		return ctx, err
	}
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+tok), nil
}

// bearerFor is bearer for an Exec of the given timeout_s: its token outlives the call (E17B-R34).
func (l *leaseSession) bearerFor(ctx context.Context, timeoutS uint32) (context.Context, error) {
	tok, err := l.ref.TokenFor(time.Duration(timeoutS) * time.Second)
	if err != nil {
		return ctx, err
	}
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+tok), nil
}

// setMode sends set_mode (epoch 1) and returns once the worker has acknowledged it.
func (l *leaseSession) setMode(ctx context.Context, client pb.SandboxExecClient) error {
	ttl := min(l.cfg.ttl(), setModeTokenMaxTTL)
	smTok, err := l.cfg.Key.MintSetMode(SetModeClaims{
		Iss: l.cfg.Iss, Sub: leaseSub, Sbx: l.key, Wrk: l.cfg.Wrk,
		Mode: l.cfg.mode(), ModeEpoch: leaseModeEpoch, IdleTimeoutS: l.cfg.IdleTimeoutS, TTL: ttl,
	})
	if err != nil {
		return err
	}
	cctx, err := l.bearer(ctx)
	if err != nil {
		return err
	}
	cctx, cancel := context.WithTimeout(cctx, setModeCallLimit)
	defer cancel()
	_, err = client.LeaseControl(cctx, &pb.LeaseControlRequest{SandboxId: l.cfg.Wrk, Op: pb.LeaseOp_LEASE_OP_SET_MODE, SetModeToken: smTok})
	return err
}

// status asks for this workspace's lease status.
func (l *leaseSession) status(ctx context.Context, client pb.SandboxExecClient) (*pb.LeaseStatus, error) {
	cctx, err := l.bearer(ctx)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(cctx, statusCallLimit)
	defer cancel()
	resp, err := client.LeaseControl(cctx, &pb.LeaseControlRequest{SandboxId: l.cfg.Wrk, Op: pb.LeaseOp_LEASE_OP_STATUS})
	if err != nil {
		return nil, err
	}
	return resp.GetStatus(), nil
}

// reset sends LeaseControl reset (ownwalk only): the worker ends this workspace's live lease
// with reason "reset" and answers once it has ended; with no lease it is a no-op. Like status it
// carries no set-mode token, mode or epoch (sandbox-caller.ts reads those for set_mode only).
func (l *leaseSession) reset(ctx context.Context, client pb.SandboxExecClient) (*pb.LeaseStatus, error) {
	cctx, err := l.bearer(ctx)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(cctx, resetCallLimit)
	defer cancel()
	resp, err := client.LeaseControl(cctx, &pb.LeaseControlRequest{SandboxId: l.cfg.Wrk, Op: pb.LeaseOp_LEASE_OP_RESET})
	if err != nil {
		return nil, err
	}
	return resp.GetStatus(), nil
}

// fresh returns the events not yet recorded for this session (nil when none), keyed on
// (at_unix_ms, state): the worker re-delivers a pending event until it is acknowledged.
func (l *leaseSession) fresh(evs []leaseEvent) []leaseEvent {
	var out []leaseEvent
	for _, e := range evs {
		k := [2]any{e.AtUnixMs, e.State}
		if l.seen[k] {
			continue
		}
		l.seen[k] = true
		out = append(out, e)
	}
	return out
}

func hasStart(evs []leaseEvent) bool {
	for _, e := range evs {
		if e.State == "start" {
			return true
		}
	}
	return false
}

// leaseSessionFor returns the session's lease state, creating it on first use.
func (r *Replayer) leaseSessionFor(key string) *leaseSession {
	r.leaseMu.Lock()
	defer r.leaseMu.Unlock()
	ls := r.leaseSessions[key]
	if ls == nil {
		ls = newLeaseSession(r.cfg.Lease, key)
		if r.leaseSessions == nil {
			r.leaseSessions = map[string]*leaseSession{}
		}
		r.leaseSessions[key] = ls
	}
	return ls
}

// NotLeaseSessions is how many sessions' first call that ran an Exec carried no lease start event:
// each ran per-exec or without a lease, so the rung is not a lease measurement and the driver exits
// non-zero. A refused call ran nothing and is not the one judged (E17B-R30: first_refused).
func (r *Replayer) NotLeaseSessions() int {
	r.leaseMu.Lock()
	defer r.leaseMu.Unlock()
	n := 0
	for _, ls := range r.leaseSessions {
		if ls.notLease {
			n++
		}
	}
	return n
}

// ConfigRefusedSessions is how many sessions ended without one call that ran an Exec after seeing a configuration
// refusal (E17B-R42): the rung's configuration is broken (a stale mode epoch, no lease support, a token bound to
// the wrong sandbox), not loaded, so the driver exits non-zero. Load refusals stay outcomes.
func (r *Replayer) ConfigRefusedSessions() int {
	n, _ := r.configRefused()
	return n
}

func (r *Replayer) configRefused() (int, []string) {
	r.leaseMu.Lock()
	defer r.leaseMu.Unlock()
	n, classes := 0, map[string]bool{}
	for _, ls := range r.leaseSessions {
		if !ls.checked && ls.configRefused != "" {
			n++
			classes[ls.configRefused] = true
		}
	}
	out := make([]string, 0, len(classes))
	for c := range classes {
		out = append(out, c)
	}
	sort.Strings(out)
	return n, out
}

// leaseRunVerdict is the lease run's own failure, after the run (nil without lease mode): sessions whose first call
// that ran carried no start (not_lease), or that ran none after a configuration refusal (E17B-R42).
func leaseRunVerdict(r *Replayer) error {
	if r.cfg.Lease == nil {
		return nil
	}
	if n := r.NotLeaseSessions(); n > 0 {
		return fmt.Errorf("%d session(s) not_lease: the first call that ran an Exec carried no lease start event, so it ran outside a lease; this rung is not a lease measurement (a refused first call is first_refused, not judged)", n)
	}
	if n, classes := r.configRefused(); n > 0 {
		return fmt.Errorf("%d session(s) ran no call after a configuration refusal (%s): the rung's mode, lease support or token binding is wrong, so it is not a lease measurement (load refusals are outcomes; these are not)", n, strings.Join(classes, ", "))
	}
	return nil
}

// beginLeaseSession registers the session (so the sweep covers it even if set_mode fails) and sends
// its set_mode. A non-nil error fails the session: no Exec is sent for it.
func (r *Replayer) beginLeaseSession(ctx context.Context, key string) (*leaseSession, error) {
	ls := r.leaseSessionFor(key)
	if err := ls.setMode(ctx, r.client); err != nil {
		return ls, err
	}
	return ls, nil
}

// setModeFailedRow is the calls.jsonl row of a session whose set_mode failed: its first call,
// never sent (execs 0). It is not first_lease: no lease ran (PR #34 nit; a count of first_lease rows,
// the Task 11 walk cost, must not include it).
func (r *Replayer) setModeFailedRow(key string, s Session, c Call, send time.Time, err error) callRecord {
	return callRecord{
		Ts: send.UTC().Format(time.RFC3339Nano), TMs: ms(send.Sub(r.t0)),
		Session: key, Trace: s.ID, Provider: s.Provider, Call: c.I, Class: c.Class,
		PlannedDurMs: c.DurMs, PlannedGapMs: c.GapMs,
		Status: "err", Cause: causeSetMode, Msg: "set_mode: " + err.Error(),
		InWindow: !send.Before(r.warmEnd) && send.Before(r.end), Tmpfs: s.Tmpfs,
	}
}

// sweepLeases asks every started session's workspace for its lease status and writes one
// lease-tail.jsonl row per key, in key order. It runs after every session has ended, whether or not
// some failed; a key whose status call fails is a {key, error} row, never dropped.
func (r *Replayer) sweepLeases(ctx context.Context) {
	r.leaseMu.Lock()
	keys := make([]string, 0, len(r.leaseSessions))
	for k := range r.leaseSessions {
		keys = append(keys, k)
	}
	r.leaseMu.Unlock()
	sort.Strings(keys)
	rows := make([]leaseTailRow, len(keys))
	sem := make(chan struct{}, sweepParallel)
	var wg sync.WaitGroup
	for i, k := range keys {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			row := leaseTailRow{Key: k, SweptAtUnixMs: time.Now().UnixMilli()}
			st, err := r.leaseSessionFor(k).status(ctx, r.client)
			switch {
			case err != nil:
				row.Error = err.Error()
			case st == nil:
				row.Error = errors.New("empty status").Error()
			default:
				row.State = st.GetState()
				row.Processes = trackedOf(st.GetProcesses())
				if p := st.GetPending(); p != nil {
					e := eventOf(p)
					row.Pending = &e
					if e.procs != nil {
						row.PendingProcesses, row.PendingTracked = e.procs.Processes, e.procs.Tracked
					}
				}
			}
			rows[i] = row
		}()
	}
	wg.Wait()
	for _, row := range rows {
		r.rec.LeaseTail(row)
	}
}
