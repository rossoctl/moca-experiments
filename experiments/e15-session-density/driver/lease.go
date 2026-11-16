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
	"sync"
	"time"

	"google.golang.org/grpc/metadata"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const (
	leaseModeEpoch    = 1       // the epoch of the set_mode every session sends, and of its Exec tokens
	leaseModeName     = "lease" // the JWT mode claim
	leaseSub          = "e15-driver"
	leaseTenant       = "e15"
	leaseDefaultTTL   = 300 * time.Second // Exec token TTL, refreshed before it runs out
	setModeCallLimit  = 120 * time.Second // client-side bound on one set_mode
	statusCallLimit   = 30 * time.Second  // client-side bound on one status call of the sweep
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
}

func (c *LeaseConfig) ttl() time.Duration {
	if c.TokenTTL > 0 {
		return c.TokenTTL
	}
	return leaseDefaultTTL
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
	return leaseEvent{State: e.GetState(), Reason: e.GetReason(), AtUnixMs: e.GetAtUnixMs(), AgeMs: e.GetAgeMs(), Mode: modeName(e.GetMode())}
}

// leaseTailRow is one lease-tail.jsonl line: the end-of-run status of one session's workspace.
// A status call that failed is {key, error}. state is none | active | expiring; pending is the
// last undelivered event, and a lease still live at the sweep is the matcher's live_at_stop.
type leaseTailRow struct {
	Key     string      `json:"key"`
	State   string      `json:"state,omitempty"`
	Pending *leaseEvent `json:"pending,omitempty"`
	Error   string      `json:"error,omitempty"`
}

// leaseSession is one session's lease state. Its methods are called from the session's own
// goroutine, one call at a time (the sweep runs after every session has ended).
type leaseSession struct {
	key      string
	cfg      *LeaseConfig
	ref      *Refresher
	seen     map[[2]any]bool // (at_unix_ms, state) of every event already recorded
	started  bool            // the first call has been handed out
	notLease bool            // the first call carried no start event
}

func newLeaseSession(cfg *LeaseConfig, key string) *leaseSession {
	// The epoch is fixed when the Refresher is built: it is the epoch of the set_mode this
	// session sends and the worker acknowledges.
	ref := NewRefresher(cfg.Key, SandboxClaims{
		Iss: cfg.Iss, Sub: leaseSub, Tenant: leaseTenant, Sbx: key, Wrk: cfg.Wrk,
		Mode: leaseModeName, ModeEpoch: leaseModeEpoch, IdleTimeoutS: cfg.IdleTimeoutS, TTL: cfg.ttl(),
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

// setMode sends set_mode (epoch 1) and returns once the worker has acknowledged it.
func (l *leaseSession) setMode(ctx context.Context, client pb.SandboxExecClient) error {
	ttl := min(l.cfg.ttl(), setModeTokenMaxTTL)
	smTok, err := l.cfg.Key.MintSetMode(SetModeClaims{
		Iss: l.cfg.Iss, Sub: leaseSub, Sbx: l.key, Wrk: l.cfg.Wrk,
		Mode: leaseModeName, ModeEpoch: leaseModeEpoch, IdleTimeoutS: l.cfg.IdleTimeoutS, TTL: ttl,
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

// NotLeaseSessions is how many sessions' first call carried no lease start event: each ran per-exec
// or without a lease, so the rung is not a lease measurement and the driver exits non-zero.
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
// never sent (execs 0).
func (r *Replayer) setModeFailedRow(key string, s Session, c Call, send time.Time, err error) callRecord {
	return callRecord{
		Ts: send.UTC().Format(time.RFC3339Nano), TMs: ms(send.Sub(r.t0)),
		Session: key, Trace: s.ID, Provider: s.Provider, Call: c.I, Class: c.Class,
		PlannedDurMs: c.DurMs, PlannedGapMs: c.GapMs,
		Status: "err", Cause: causeSetMode, Msg: "set_mode: " + err.Error(),
		InWindow: !send.Before(r.warmEnd) && send.Before(r.end), FirstLease: true, Tmpfs: s.Tmpfs,
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
			st, err := r.leaseSessionFor(k).status(ctx, r.client)
			row := leaseTailRow{Key: k}
			switch {
			case err != nil:
				row.Error = err.Error()
			case st == nil:
				row.Error = errors.New("empty status").Error()
			default:
				row.State = st.GetState()
				if p := st.GetPending(); p != nil {
					e := eventOf(p)
					row.Pending = &e
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
