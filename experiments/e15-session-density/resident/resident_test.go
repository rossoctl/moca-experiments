package vmpool

// E15 resident-arm tests (rig-only patch; never in the moca repo). They run against
// the in-tree fakeLauncher (launcher_fake_test.go), whose fakeVM refuses a second Run
// unless allowReuse is set — the one test-helper edit resident.patch carries.
//
// Every resident pool here sets Config.Resident explicitly rather than through
// E15_RESIDENT, so the suite is hermetic whatever the caller's environment holds;
// TestResidentConfigFromEnv covers the env path on its own.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const residentKey = "k"

// residentPool builds a resident-mode pool over lc: standby depth 0 (the resident
// arm's setting, SPEC §7.1), the given idle timeout (0 = never), a fake clock.
func residentPool(t *testing.T, lc Launcher, idle time.Duration) (*pool, *fakeClock) {
	t.Helper()
	return residentPoolDepth(t, lc, idle, 0)
}

func residentPoolDepth(t *testing.T, lc Launcher, idle time.Duration, depth int) (*pool, *fakeClock) {
	t.Helper()
	// Hermetic: the env path must not leak into a test that sets the fields itself.
	t.Setenv("E15_RESIDENT", "")
	t.Setenv("E15_RESIDENT_IDLE_S", "")
	clk := newFakeClock()
	cfg := Config{
		VMM:               lc.Kind(),
		SnapshotDir:       t.TempDir(),
		WorkspaceRoot:     t.TempDir(),
		MaxRuns:           16,
		MaxCommittedBytes: 32 << 30,
		StandbyDepth:      depth,
		Resident:          true,
		ResidentIdle:      idle,
	}
	p, err := New(cfg, lc, clk)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = p.Close() })
	return p.(*pool), clk
}

func reusableFake() *fakeLauncher {
	lc := newFakeLauncher()
	lc.allowReuse = true
	return lc
}

func execOK(t *testing.T, p Pool, cmd string) {
	t.Helper()
	if _, err := p.Exec(context.Background(), residentKey, Exec{Command: cmd, TimeoutS: 3600}, &capturingSink{}); err != nil {
		t.Fatalf("Exec %q: %v", cmd, err)
	}
}

// Three Execs for one key: one Restore, zero Destroy while the key is not idle.
func TestResidentReusesVM(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 300*time.Second)
	for i := 0; i < 3; i++ {
		var out capturingSink
		if _, err := p.Exec(context.Background(), residentKey, Exec{Command: fmt.Sprintf("c%d", i), TimeoutS: 3600}, &out); err != nil {
			t.Fatalf("Exec %d: %v", i, err)
		}
		if out.out() != fmt.Sprintf("c%d", i) {
			t.Fatalf("Exec %d stdout = %q", i, out.out())
		}
	}
	if got := lc.createdCount(); got != 1 {
		t.Fatalf("created %d VMs for 3 Execs on one key, want 1 (resident reuse)", got)
	}
	if got := lc.destroyedFor(residentKey); got != 0 {
		t.Fatalf("destroyed %d VMs before idle, want 0", got)
	}
	if got := lc.liveCount(); got != 1 {
		t.Fatalf("live VMs = %d, want 1", got)
	}
	if st := p.Stats(); st.ResidentVMs != 1 {
		t.Fatalf("Stats.ResidentVMs = %d, want 1", st.ResidentVMs)
	}
}

// Two concurrent Execs for one key never overlap — even though the fake launcher
// reports SerializesExecsPerRun()==false: the guest agent has ONE parked shell.
func TestResidentSerialisesOneKey(t *testing.T) {
	lc := reusableFake()
	if lc.SerializesExecsPerRun() {
		t.Fatal("precondition: fake launcher must not serialize, so this tests the resident gate")
	}
	p, _ := residentPool(t, lc, 0)

	var running, maxRunning, entered atomic.Int32
	release := make(chan struct{})
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		n := running.Add(1)
		for {
			m := maxRunning.Load()
			if n <= m || maxRunning.CompareAndSwap(m, n) {
				break
			}
		}
		entered.Add(1)
		if c.Command == "first" {
			<-release
		}
		running.Add(-1)
		return Result{}, nil
	})

	errs := make(chan error, 2)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "first", TimeoutS: 3600}, &capturingSink{})
		errs <- err
	}()
	waitFor(t, func() bool { return entered.Load() == 1 })
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "second", TimeoutS: 3600}, &capturingSink{})
		errs <- err
	}()
	// The second Exec must be parked on the gate, not inside Run.
	time.Sleep(50 * time.Millisecond)
	if got := entered.Load(); got != 1 {
		t.Fatalf("second Exec entered Run while the first was still running (entered=%d)", got)
	}
	close(release)
	for i := 0; i < 2; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("Exec: %v", err)
		}
	}
	if got := maxRunning.Load(); got != 1 {
		t.Fatalf("max concurrent Runs on one key = %d, want 1", got)
	}
	if got := lc.createdCount(); got != 1 {
		t.Fatalf("created %d VMs, want 1", got)
	}
}

// Idle 300 s, clock +301 s, sweep -> one Destroy; the next Exec restores fresh.
func TestResidentIdleDestroy(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 300*time.Second)
	execOK(t, p, "a")
	clk.Advance(301 * time.Second)
	p.sweep(clk.Now())
	waitFor(t, func() bool { return lc.destroyedFor(residentKey) == 1 })
	if got := lc.liveCount(); got != 0 {
		t.Fatalf("live VMs after idle destroy = %d, want 0", got)
	}
	execOK(t, p, "b")
	if got := lc.createdCount(); got != 2 {
		t.Fatalf("created %d VMs, want 2 (a cold wake after the idle destroy)", got)
	}
	st := p.Stats()
	if st.ColdAcquires[ColdParked] != 1 {
		t.Fatalf("ColdAcquires[parked] = %d, want 1 (the cold wake is counted as a parked acquire): %v",
			st.ColdAcquires[ColdParked], st.ColdAcquires)
	}
}

// Under the idle boundary nothing is destroyed: 299 s is not 300 s.
func TestResidentIdleNotBeforeThreshold(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 300*time.Second)
	execOK(t, p, "a")
	clk.Advance(299 * time.Second)
	p.sweep(clk.Now())
	time.Sleep(20 * time.Millisecond)
	if got := lc.destroyedFor(residentKey); got != 0 {
		t.Fatalf("destroyed %d at 299 s idle, want 0", got)
	}
}

// Review Focus 5: an in-flight Exec holds the gate at 301 s -> the sweep does not
// destroy; idle is measured from the Exec's END, so 301 s after it ends -> destroyed.
func TestResidentIdleRespectsGate(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 300*time.Second)
	execOK(t, p, "warm")

	var entered atomic.Bool
	release := make(chan struct{})
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		if c.Command == "long" {
			entered.Store(true)
			<-release
		}
		return Result{}, nil
	})
	done := make(chan error, 1)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "long", TimeoutS: 3600}, &capturingSink{})
		done <- err
	}()
	waitFor(t, entered.Load)
	clk.Advance(301 * time.Second)
	p.sweep(clk.Now())
	time.Sleep(20 * time.Millisecond)
	if got := lc.destroyedFor(residentKey); got != 0 {
		t.Fatalf("sweep destroyed the resident VM under an in-flight Exec (destroyed=%d)", got)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatalf("long Exec: %v", err)
	}
	p.sweep(clk.Now()) // idle 0 s since the Exec ended
	time.Sleep(20 * time.Millisecond)
	if got := lc.destroyedFor(residentKey); got != 0 {
		t.Fatalf("destroyed right after a long Exec ended (destroyed=%d); idle must count from the Exec's end", got)
	}
	clk.Advance(301 * time.Second)
	p.sweep(clk.Now())
	waitFor(t, func() bool { return lc.destroyedFor(residentKey) == 1 })
}

// slowDestroyLauncher wraps the fake so a VM's Destroy blocks until released: it
// widens the window in which a gate opened too early would let a fresh VM restore
// and mount the workspace while the old one still holds it.
type slowDestroyLauncher struct {
	*fakeLauncher
	gate chan struct{}
}

type slowDestroyVM struct {
	*fakeVM
	gate chan struct{}
}

func (l *slowDestroyLauncher) Restore(ctx context.Context, req RestoreRequest) (VM, error) {
	vm, err := l.fakeLauncher.Restore(ctx, req)
	if err != nil {
		return nil, err
	}
	return &slowDestroyVM{fakeVM: vm.(*fakeVM), gate: l.gate}, nil
}

func (v *slowDestroyVM) Destroy() error { <-v.gate; return v.fakeVM.Destroy() }

// Review Focus 5 and the one-mount invariant: a command queued behind an idle destroy
// gets a FRESH VM, and that VM is restored only after the old one is gone.
func TestResidentQueuedCommandAfterIdleGetsFreshVM(t *testing.T) {
	fl := reusableFake()
	lc := &slowDestroyLauncher{fakeLauncher: fl, gate: make(chan struct{})}
	p, clk := residentPool(t, lc, 300*time.Second)
	execOK(t, p, "a")

	var liveAtRestore atomic.Int32
	liveAtRestore.Store(-1)
	fl.setBeforeRestore(func(RestoreRequest) { liveAtRestore.Store(int32(fl.liveCount())) })

	clk.Advance(301 * time.Second)
	p.sweep(clk.Now()) // detaches the resident VM; its Destroy is now blocked on lc.gate
	done := make(chan error, 1)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "queued", TimeoutS: 3600}, &capturingSink{})
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	if got := fl.createdCount(); got != 1 {
		t.Fatalf("a fresh VM was restored (created=%d) while the old resident VM was still being destroyed", got)
	}
	select {
	case err := <-done:
		t.Fatalf("queued Exec returned before the old VM was destroyed: %v", err)
	default:
	}
	close(lc.gate)
	if err := <-done; err != nil {
		t.Fatalf("queued Exec: %v", err)
	}
	if got := fl.createdCount(); got != 2 {
		t.Fatalf("created %d, want 2", got)
	}
	if got := liveAtRestore.Load(); got != 0 {
		t.Fatalf("live VMs at the fresh Restore = %d, want 0 (old VM must be gone first)", got)
	}
}

// Idle 0 = infinite: clock +10 h, no Destroy, and the next Exec still reuses.
func TestResidentInfiniteNeverIdles(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 0)
	execOK(t, p, "a")
	clk.Advance(10 * time.Hour)
	p.sweep(clk.Now())
	time.Sleep(20 * time.Millisecond)
	if got := lc.destroyedFor(residentKey); got != 0 {
		t.Fatalf("destroyed %d with idle=0 (infinite), want 0", got)
	}
	execOK(t, p, "b")
	if got := lc.createdCount(); got != 1 {
		t.Fatalf("created %d, want 1", got)
	}
}

const deadAgentText = "guest-agent: a previous command timed out; the parked shell was killed and this agent is dead"

// The guest agent's dead-agent error retires the VM; the next Exec restores fresh.
func TestResidentRetiresDeadAgent(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	execOK(t, p, "a")
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		if c.Command == "doomed" {
			return Result{}, fmt.Errorf("%w: %s", ErrGuest, deadAgentText)
		}
		return Result{}, nil
	})
	if _, err := p.Exec(context.Background(), residentKey, Exec{Command: "doomed", TimeoutS: 3600}, &capturingSink{}); !errors.Is(err, ErrGuest) {
		t.Fatalf("Exec on a dead agent: err = %v, want ErrGuest", err)
	}
	if got := lc.destroyedFor(residentKey); got != 1 {
		t.Fatalf("destroyed %d after the dead-agent error, want 1", got)
	}
	execOK(t, p, "b")
	if got := lc.createdCount(); got != 2 {
		t.Fatalf("created %d, want 2 (fresh VM after retirement)", got)
	}
	if st := p.Stats(); st.InFlight != 1 || st.ResidentVMs != 1 {
		t.Fatalf("after retire+fresh: InFlight=%d ResidentVMs=%d, want 1/1", st.InFlight, st.ResidentVMs)
	}
}

// The dead-agent text on stderr (not as an error) retires the VM too.
func TestResidentRetiresDeadAgentOnStderr(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		// Split across two chunks, so the detector must not rely on one Write.
		out.Stderr([]byte(deadAgentText[:20]))
		out.Stderr([]byte(deadAgentText[20:] + "\n"))
		return Result{ExitCode: 1}, nil
	})
	if _, err := p.Exec(context.Background(), residentKey, Exec{Command: "x", TimeoutS: 3600}, &capturingSink{}); err != nil {
		t.Fatalf("Exec: %v", err)
	}
	if got := lc.destroyedFor(residentKey); got != 1 {
		t.Fatalf("destroyed %d after dead-agent text on stderr, want 1", got)
	}
}

// A timeout kills the guest's parked shell, so it retires the VM.
func TestResidentRetiresOnTimeout(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 0)
	execOK(t, p, "a")
	var entered atomic.Bool
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		if c.Command == "hang" {
			entered.Store(true)
			<-c.ctxDone
			return Result{}, ErrAborted
		}
		return Result{}, nil
	})
	done := make(chan error, 1)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "hang", TimeoutS: 5}, &capturingSink{})
		done <- err
	}()
	waitFor(t, entered.Load)
	clk.Advance(6 * time.Second)
	if err := <-done; !errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want ErrTimeout", err)
	}
	if got := lc.destroyedFor(residentKey); got != 1 {
		t.Fatalf("destroyed %d after a timeout, want 1", got)
	}
	execOK(t, p, "b")
	if got := lc.createdCount(); got != 2 {
		t.Fatalf("created %d, want 2", got)
	}
}

// A non-zero exit is not a dead agent: the VM is kept.
func TestResidentKeepsVMOnNonZeroExit(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) { return Result{ExitCode: 1}, nil })
	for i := 0; i < 2; i++ {
		res, err := p.Exec(context.Background(), residentKey, Exec{Command: "false", TimeoutS: 3600}, &capturingSink{})
		if err != nil || res.ExitCode != 1 {
			t.Fatalf("Exec: res=%+v err=%v", res, err)
		}
	}
	if lc.createdCount() != 1 || lc.destroyedFor(residentKey) != 0 {
		t.Fatalf("created=%d destroyed=%d, want 1/0", lc.createdCount(), lc.destroyedFor(residentKey))
	}
}

// E15_RESIDENT unset: every Exec restores and destroys exactly one VM, as stock.
func TestStockUnchanged(t *testing.T) {
	t.Setenv("E15_RESIDENT", "")
	_ = os.Unsetenv("E15_RESIDENT")
	t.Setenv("E15_RESIDENT_IDLE_S", "")
	_ = os.Unsetenv("E15_RESIDENT_IDLE_S")
	p, lc, _ := testPool(t)
	if p.(*pool).cfg.Resident {
		t.Fatal("Config.Resident is true with E15_RESIDENT unset")
	}
	for i := 0; i < 3; i++ {
		execOK(t, p, fmt.Sprintf("c%d", i))
		if got := lc.destroyedFor(residentKey); got != i+1 {
			t.Fatalf("after Exec %d: destroyed %d, want %d (one per Exec)", i, got, i+1)
		}
	}
	// testPool's StandbyDepth is the default 2, so replenishment may add standbys;
	// what must hold is that every Exec consumed and destroyed its own VM.
	if got := lc.destroyedFor(residentKey); got != 3 {
		t.Fatalf("destroyed %d, want 3", got)
	}
	if got := p.Stats().ResidentVMs; got != 0 {
		t.Fatalf("Stats.ResidentVMs = %d in stock mode, want 0", got)
	}
}

// The budget is charged once at acquire, held across Execs, released at destroy.
func TestResidentBudgetReleasedAtDestroy(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPool(t, lc, 300*time.Second)
	per := PerVMBytes(p.cfg)
	for i := 0; i < 3; i++ {
		execOK(t, p, "c")
		if got := p.Stats().CommittedBytes; got != per {
			t.Fatalf("after Exec %d: committed %d, want one PerVM %d", i, got, per)
		}
	}
	clk.Advance(301 * time.Second)
	p.sweep(clk.Now())
	waitFor(t, func() bool { return lc.destroyedFor(residentKey) == 1 })
	if got := p.Stats().CommittedBytes; got != 0 {
		t.Fatalf("committed after idle destroy = %d, want 0", got)
	}
	if got := p.Stats().InFlight; got != 0 {
		t.Fatalf("InFlight after idle destroy = %d, want 0", got)
	}
}

// No standby replenishment for a key that holds a resident VM, even at depth > 0.
func TestResidentNoReplenishWhileResident(t *testing.T) {
	lc := reusableFake()
	p, clk := residentPoolDepth(t, lc, 0, 2)
	execOK(t, p, "a")
	clk.Advance(5 * time.Second) // well past ReplenishDelay
	time.Sleep(20 * time.Millisecond)
	if got := lc.createdCount(); got != 1 {
		t.Fatalf("created %d, want 1: a resident key must not be replenished", got)
	}
	if got := p.Stats().StandbysResident; got != 0 {
		t.Fatalf("standbys = %d, want 0", got)
	}
}

// Depth 0 is honoured in resident mode (stock Normalize maps 0 to the default 2).
func TestResidentDepthZeroKept(t *testing.T) {
	p, _ := residentPool(t, reusableFake(), 0)
	if p.cfg.StandbyDepth != 0 {
		t.Fatalf("StandbyDepth = %d, want 0 in resident mode", p.cfg.StandbyDepth)
	}
}

// Close destroys an idle resident VM: no leak at shutdown.
func TestResidentCloseDestroysResident(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	execOK(t, p, "a")
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := lc.liveCount(); got != 0 {
		t.Fatalf("live VMs after Close = %d, want 0", got)
	}
	if got := lc.destroyedFor(residentKey); got != 1 {
		t.Fatalf("destroyed %d, want 1", got)
	}
}

// An Exec running across Close retires its VM on the way out instead of keeping it.
func TestResidentCloseDuringExecRetires(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	var entered atomic.Bool
	release := make(chan struct{})
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		entered.Store(true)
		<-release
		return Result{}, nil
	})
	done := make(chan error, 1)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "x", TimeoutS: 3600}, &capturingSink{})
		done <- err
	}()
	waitFor(t, entered.Load)
	closed := make(chan error, 1)
	go func() { closed <- p.Close() }()
	if err := <-closed; err != nil {
		t.Fatalf("Close: %v", err)
	}
	close(release)
	<-done
	waitFor(t, func() bool { return lc.liveCount() == 0 })
}

// Many keys at once: one VM per key, no cross-key serialisation, all reused.
func TestResidentManyKeys(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	keys := []string{"a", "b", "c", "d"}
	var wg sync.WaitGroup
	errs := make(chan error, 3*len(keys))
	for _, k := range keys {
		wg.Add(1)
		go func(k string) {
			defer wg.Done()
			for i := 0; i < 3; i++ {
				_, err := p.Exec(context.Background(), k, Exec{Command: "x", TimeoutS: 3600}, &capturingSink{})
				errs <- err
			}
		}(k)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("Exec: %v", err)
		}
	}
	if got := lc.createdCount(); got != len(keys) {
		t.Fatalf("created %d, want %d (one per key)", got, len(keys))
	}
	if got := p.Stats().CommittedBytes; got != int64(len(keys))*PerVMBytes(p.cfg) {
		t.Fatalf("committed %d, want %d", got, int64(len(keys))*PerVMBytes(p.cfg))
	}
}

// The env path: E15_RESIDENT=1 with E15_RESIDENT_IDLE_S fills Config; bad values refuse.
func TestResidentConfigFromEnv(t *testing.T) {
	base := func(t *testing.T) Config {
		return Config{VMM: Firecracker, SnapshotDir: t.TempDir(), WorkspaceRoot: t.TempDir(),
			MaxRuns: 4, MaxCommittedBytes: 32 << 30}
	}
	t.Run("on", func(t *testing.T) {
		t.Setenv("E15_RESIDENT", "1")
		t.Setenv("E15_RESIDENT_IDLE_S", "300")
		p, err := New(base(t), reusableFake(), newFakeClock())
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		defer p.Close()
		cfg := p.(*pool).cfg
		if !cfg.Resident || cfg.ResidentIdle != 300*time.Second {
			t.Fatalf("Resident=%v ResidentIdle=%v, want true/300s", cfg.Resident, cfg.ResidentIdle)
		}
	})
	t.Run("infinite", func(t *testing.T) {
		t.Setenv("E15_RESIDENT", "1")
		t.Setenv("E15_RESIDENT_IDLE_S", "0")
		p, err := New(base(t), reusableFake(), newFakeClock())
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		defer p.Close()
		if cfg := p.(*pool).cfg; !cfg.Resident || cfg.ResidentIdle != 0 {
			t.Fatalf("Resident=%v ResidentIdle=%v, want true/0", cfg.Resident, cfg.ResidentIdle)
		}
	})
	for name, env := range map[string][2]string{
		"missing idle":  {"1", ""},
		"negative idle": {"1", "-5"},
		"garbage idle":  {"1", "5m"},
		"bad switch":    {"yes", "300"},
		"idle w/o on":   {"", "300"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("E15_RESIDENT", env[0])
			t.Setenv("E15_RESIDENT_IDLE_S", env[1])
			if p, err := New(base(t), reusableFake(), newFakeClock()); err == nil {
				p.Close()
				t.Fatalf("New accepted E15_RESIDENT=%q E15_RESIDENT_IDLE_S=%q", env[0], env[1])
			}
		})
	}
}

// The driver's end-of-session Exec destroys the resident VM and runs nothing; on an
// unknown key it is a no-op that creates no run and acquires no VM.
func TestResidentEndSession(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	if _, err := p.Exec(context.Background(), "never-seen", Exec{Command: ResidentEndSession, TimeoutS: 30}, &capturingSink{}); err != nil {
		t.Fatalf("end-session on an unknown key: %v", err)
	}
	if lc.createdCount() != 0 || p.Stats().ActiveRuns != 0 {
		t.Fatalf("end-session on an unknown key created=%d runs=%d, want 0/0", lc.createdCount(), p.Stats().ActiveRuns)
	}
	execOK(t, p, "a")
	var out capturingSink
	res, err := p.Exec(context.Background(), residentKey, Exec{Command: ResidentEndSession, TimeoutS: 30}, &out)
	if err != nil || res.ExitCode != 0 || out.out() != "" {
		t.Fatalf("end-session: res=%+v err=%v stdout=%q, want exit 0, no output", res, err, out.out())
	}
	if got := lc.destroyedFor(residentKey); got != 1 {
		t.Fatalf("destroyed %d after end-session, want 1", got)
	}
	st := p.Stats()
	if st.CommittedBytes != 0 || st.ResidentVMs != 0 || st.ResidentEnded != 1 {
		t.Fatalf("after end-session: committed=%d residentVMs=%d ended=%d, want 0/0/1",
			st.CommittedBytes, st.ResidentVMs, st.ResidentEnded)
	}
	// A second end-session is a no-op; the next command is a fresh VM.
	if _, err := p.Exec(context.Background(), residentKey, Exec{Command: ResidentEndSession, TimeoutS: 30}, &capturingSink{}); err != nil {
		t.Fatalf("second end-session: %v", err)
	}
	execOK(t, p, "b")
	if got := lc.createdCount(); got != 2 {
		t.Fatalf("created %d, want 2", got)
	}
}

// A first-exec cold acquire is still counted as first-exec, then reuses are counted.
func TestResidentCountsFirstExecAndReuses(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	for i := 0; i < 3; i++ {
		execOK(t, p, "x")
	}
	st := p.Stats()
	if st.ColdAcquires[ColdFirstExec] != 1 || st.ResidentReuses != 2 {
		t.Fatalf("ColdAcquires=%v ResidentReuses=%d, want first-exec 1 and 2 reuses", st.ColdAcquires, st.ResidentReuses)
	}
}

// An abort while waiting on the gate holds no VM and no charge, and the resident VM
// survives it.
func TestResidentAbortWhileQueued(t *testing.T) {
	lc := reusableFake()
	p, _ := residentPool(t, lc, 0)
	var entered atomic.Bool
	release := make(chan struct{})
	lc.setRunFn(func(v *fakeVM, c Command, out Sink) (Result, error) {
		if c.Command == "long" {
			entered.Store(true)
			<-release
		}
		return Result{}, nil
	})
	done := make(chan error, 1)
	go func() {
		_, err := p.Exec(context.Background(), residentKey, Exec{Command: "long", TimeoutS: 3600}, &capturingSink{})
		done <- err
	}()
	waitFor(t, entered.Load)
	ctx, cancel := context.WithCancel(context.Background())
	queued := make(chan error, 1)
	go func() {
		_, err := p.Exec(ctx, residentKey, Exec{Command: "queued", TimeoutS: 3600}, &capturingSink{})
		queued <- err
	}()
	time.Sleep(20 * time.Millisecond)
	cancel()
	if err := <-queued; !errors.Is(err, ErrAborted) {
		t.Fatalf("queued Exec after abort: %v, want ErrAborted", err)
	}
	if got := p.Stats().CommittedBytes; got != PerVMBytes(p.cfg) {
		t.Fatalf("committed %d, want one PerVM (the aborted waiter must hold nothing)", got)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatalf("long Exec: %v", err)
	}
	if lc.createdCount() != 1 || lc.destroyedFor(residentKey) != 0 {
		t.Fatalf("created=%d destroyed=%d, want 1/0", lc.createdCount(), lc.destroyedFor(residentKey))
	}
}

// residentKVMPool is poolFor's real-launcher shape in resident mode, depth 0.
func residentKVMPool(t *testing.T, idle time.Duration) (Pool, Launcher) {
	t.Helper()
	requireKVM(t)
	t.Setenv("E15_RESIDENT", "")
	t.Setenv("E15_RESIDENT_IDLE_S", "")
	lc := launcherForArm(t)
	snapshotDir := envOr("SH_SNAPSHOT_IMAGE_DIR", "/srv/snapshots/swebench-py311")
	cfg := Config{
		VMM:               lc.Kind(),
		SnapshotDir:       t.TempDir(),
		WorkspaceRoot:     sameDeviceSiblingDir(t, snapshotDir),
		MaxRuns:           4,
		MaxCommittedBytes: 32 << 30,
		Resident:          true,
		ResidentIdle:      idle,
	}
	p, err := New(cfg, lc, RealClock())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = p.Close() })
	return p, lc
}

// On a real guest (rig, SH_KVM=1): commands reuse one VM — guest state written by
// one command (a file in guest tmpfs, outside the workspace) is visible to the next,
// which per-Exec VMs can never show — the workspace survives, and the end-session
// Exec destroys the VM so the next command sees a fresh guest.
func TestResidentKVMReuseAndEndSession(t *testing.T) {
	p, _ := residentKVMPool(t, 0)
	ctx := context.Background()
	const key = "e15-resident-kvm"
	run := func(cmd string) string {
		t.Helper()
		var out capturingSink
		res, err := p.Exec(ctx, key, Exec{Command: cmd, TimeoutS: 60}, &out)
		if err != nil || res.ExitCode != 0 {
			t.Fatalf("Exec %q: res=%+v err=%v", cmd, res, err)
		}
		return out.out()
	}
	run("echo resident > /tmp/e15-marker; echo ws > e15-ws.txt")
	if got := run("cat /tmp/e15-marker; cat e15-ws.txt"); got != "resident\nws\n" {
		t.Fatalf("second command saw %q, want the first command's guest tmpfs file and workspace file", got)
	}
	if st := p.Stats(); st.ResidentVMs != 1 || st.ResidentReuses != 1 {
		t.Fatalf("ResidentVMs=%d ResidentReuses=%d, want 1/1", st.ResidentVMs, st.ResidentReuses)
	}
	run(ResidentEndSession)
	if got := run("cat /tmp/e15-marker 2>/dev/null || echo fresh; cat e15-ws.txt"); got != "fresh\nws\n" {
		t.Fatalf("after end-session saw %q, want a fresh guest with the workspace kept", got)
	}
}

// On a real guest: a command that times out kills the parked shell; the VM is retired
// and the next command runs on a fresh guest instead of hitting the dead agent.
func TestResidentKVMRetiresAfterTimeout(t *testing.T) {
	p, _ := residentKVMPool(t, 0)
	ctx := context.Background()
	const key = "e15-resident-kvm-timeout"
	if _, err := p.Exec(ctx, key, Exec{Command: "sleep 30", TimeoutS: 2}, &capturingSink{}); !errors.Is(err, ErrTimeout) {
		t.Fatalf("sleep 30 with timeout 2: err = %v, want ErrTimeout", err)
	}
	var out capturingSink
	res, err := p.Exec(ctx, key, Exec{Command: "echo alive", TimeoutS: 60}, &out)
	if err != nil || res.ExitCode != 0 || out.out() != "alive\n" {
		t.Fatalf("after a timeout: res=%+v err=%v out=%q, want a fresh VM answering", res, err, out.out())
	}
	if st := p.Stats(); st.ResidentRetired != 1 {
		t.Fatalf("ResidentRetired = %d, want 1", st.ResidentRetired)
	}
}

// On a real guest: idle destroy at T_idle, then a cold wake on a fresh guest.
func TestResidentKVMIdleDestroy(t *testing.T) {
	p, _ := residentKVMPool(t, 2*time.Second)
	ctx := context.Background()
	const key = "e15-resident-kvm-idle"
	if _, err := p.Exec(ctx, key, Exec{Command: "echo x > /tmp/e15-marker", TimeoutS: 60}, &capturingSink{}); err != nil {
		t.Fatalf("Exec: %v", err)
	}
	deadline := time.Now().Add(2 * time.Minute) // the ticker runs every StandbyIdle/4
	for p.Stats().ResidentIdled == 0 {
		if time.Now().After(deadline) {
			t.Fatal("resident VM not idle-destroyed within 2 min")
		}
		p.(*pool).sweep(time.Now())
		time.Sleep(250 * time.Millisecond)
	}
	var out capturingSink
	if _, err := p.Exec(ctx, key, Exec{Command: "cat /tmp/e15-marker 2>/dev/null || echo fresh", TimeoutS: 60}, &out); err != nil || out.out() != "fresh\n" {
		t.Fatalf("cold wake: err=%v out=%q, want a fresh guest", err, out.out())
	}
}
