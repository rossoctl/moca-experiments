package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func lib(t *testing.T) *Library {
	t.Helper()
	l, err := LoadLibrary("testdata/library.json")
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func synth(n int, u1frac float64) []Session {
	var ss []Session
	for i := 0; i < n; i++ {
		u := fmt.Sprintf("u%d", i%7+2)
		if float64(i) < u1frac*float64(n) {
			u = "u1"
		}
		calls := make([]Call, 5+i%10)
		ss = append(ss, Session{ID: fmt.Sprintf("s%d", i), User: u, Calls: calls})
	}
	return ss
}

func TestLoadSmall(t *testing.T) {
	ss, err := LoadCorpus("testdata/corpus-small.jsonl")
	if err != nil || len(ss) != 3 || len(ss[0].Calls) != 4 || !ss[0].Calls[1].Chain {
		t.Fatalf("%v %d", err, len(ss))
	}
	s := mk(t, ss, 1, 1)
	for i := 0; i < 10; i++ {
		if got, _, _ := s.Next(map[string]int{}, 10); got.ID == "short" {
			t.Fatal("short session returned")
		}
	}
}

func TestSamplerDeterministic(t *testing.T) {
	ss := synth(40, 0)
	a, b := mk(t, ss, 7, 1), mk(t, ss, 7, 1)
	for i := 0; i < 50; i++ {
		x, xs, _ := a.Next(map[string]int{}, 20)
		y, ys, _ := b.Next(map[string]int{}, 20)
		if x.ID != y.ID || xs != ys {
			t.Fatalf("draw %d differs", i)
		}
	}
}

func TestSamplerUserCap(t *testing.T) {
	s := mk(t, synth(100, 0.6), 3, 0.15)
	live := map[string]int{}
	for i := 0; i < 20; i++ {
		x, _, _ := s.Next(live, 20)
		live[x.User]++
	}
	if live["u1"] > 3 {
		t.Fatalf("u1 holds %d", live["u1"])
	}
}

func TestSamplerNoReplacementThenReshuffle(t *testing.T) {
	ss := synth(10, 0)
	s := mk(t, ss, 5, 1)
	seen := map[string]bool{}
	for i := 0; i < 10; i++ {
		x, _, _ := s.Next(map[string]int{}, 10)
		if seen[x.ID] {
			t.Fatal("repeat before exhaustion")
		}
		seen[x.ID] = true
	}
	if x, _, _ := s.Next(map[string]int{}, 10); x.ID == "" {
		t.Fatal("no draw after exhaustion")
	}
}

func TestStartIndexLeavesThreeCalls(t *testing.T) {
	s := mk(t, synth(30, 0), 2, 1)
	for i := 0; i < 500; i++ {
		x, st, _ := s.Next(map[string]int{}, 30)
		if st < 0 || st > len(x.Calls)-3 {
			t.Fatalf("start %d of %d", st, len(x.Calls))
		}
	}
}

func sumRun(t *testing.T, l *Library, class string, ps []Planned) int64 {
	m := map[string]int64{}
	for _, v := range l.Classes[class] {
		m[v.Cmd] = v.Ms()
	}
	var s int64
	for _, p := range ps {
		d, ok := m[p.Cmd]
		if !ok {
			t.Fatalf("command %q not in class %s", p.Cmd, class)
		}
		s += d
	}
	return s
}

func TestPlanMatchesWork(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 12000, DurMs: 12000}, 1, "s")
	if s := sumRun(t, l, "test", ps); s > 12000 || s < 11950 {
		t.Fatalf("sum %d", s)
	}
}

func TestPlanShorterThanShortest(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 10, DurMs: 10}, 1, "s")
	if len(ps) != 1 || ps[0].Cmd != "pytest -q a" {
		t.Fatalf("%v", ps)
	}
}

func TestPlanExitDeclared(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 20000, DurMs: 20000}, 1, "s")
	if len(ps) != 1 || ps[0].Exit != 1 {
		t.Fatalf("%v", ps)
	}
}

func TestPlanChainIdleTail(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 3000, DurMs: 60000, Chain: true}, 1, "s")
	sum := sumRun(t, l, "test", ps)
	last := ps[len(ps)-1].SleepAfterMs
	if last != 60000-sum || last < 56900 {
		t.Fatalf("tail %d sum %d", last, sum)
	}
	for _, p := range ps[:len(ps)-1] {
		if p.SleepAfterMs != 0 {
			t.Fatal("tail on non-last")
		}
	}
	ps = plan(t, l, Call{I: 1, Class: "test", WorkMs: 3000, DurMs: 3000}, 1, "s")
	if ps[len(ps)-1].SleepAfterMs != 0 {
		t.Fatal("non-chain has tail")
	}
}

func TestPlanStandIn(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 3, Class: "host_infra", WorkMs: 4000, DurMs: 4000}, 1, "s")
	if ps[0].Cmd != "sleep 2.0" || ps[0].Exit != 0 {
		t.Fatalf("%v", ps[0])
	}
	if s := sumRun(t, l, "interpreter", ps[1:]); s > 2000 || s < 1950 {
		t.Fatalf("interp sum %d", s)
	}
	for _, c := range []string{"opaque", "build"} {
		ps = plan(t, l, Call{I: 2, Class: c, WorkMs: 900, DurMs: 900}, 1, "s")
		if s := sumRun(t, l, "interpreter", ps); s > 900 || s < 850 {
			t.Fatalf("%s sum %d", c, s)
		}
	}
}

func TestPlanDeterministic(t *testing.T) {
	l := lib(t)
	c := Call{I: 2, Class: "opaque", WorkMs: 5000, DurMs: 5000}
	a, b := fmt.Sprint(plan(t, l, c, 9, "s")), fmt.Sprint(plan(t, l, c, 9, "s"))
	if a != b {
		t.Fatal("differs")
	}
	// ties (i2/i3) must vary across calls
	seen := map[string]bool{}
	for i := 0; i < 40; i++ {
		seen[plan(t, l, Call{I: i, Class: "opaque", WorkMs: 500}, 9, "s")[0].Cmd] = true
	}
	if len(seen) != 2 {
		t.Fatalf("tie-break never varies: %v", seen)
	}
}

func mk(t *testing.T, ss []Session, seed int64, cap float64) *Sampler {
	t.Helper()
	s, err := NewSampler(ss, seed, cap)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func plan(t *testing.T, l *Library, c Call, seed int64, id string) []Planned {
	t.Helper()
	p, err := l.Plan(c, seed, id)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSamplerCapUnsatisfiable(t *testing.T) {
	s := mk(t, synth(10, 1.0), 1, 0.15) // every session is u1
	live := map[string]int{"u1": 3}
	if _, _, err := s.Next(live, 20); !errors.Is(err, ErrCapUnsatisfiable) {
		t.Fatalf("err %v", err)
	}
}

func TestSamplerNoRepeatAcrossCapRefill(t *testing.T) {
	ss := synth(12, 0.5) // 6 sessions for u1
	s := mk(t, ss, 4, 0.1)
	seen := map[string]bool{}
	for i := 0; i < len(ss); i++ {
		// u1 is at its cap (n=20 -> 2) for the first draws, forcing refills that must not drop sessions.
		live := map[string]int{"u1": 2}
		if i >= 6 {
			live = map[string]int{}
		}
		x, _, err := s.Next(live, 20)
		if err != nil {
			t.Fatalf("draw %d: %v", i, err)
		}
		if seen[x.ID] {
			t.Fatalf("draw %d repeats %s before every session was drawn", i, x.ID)
		}
		seen[x.ID] = true
	}
	if len(seen) != len(ss) {
		t.Fatalf("drew %d of %d", len(seen), len(ss))
	}
}

func TestNewSamplerEmpty(t *testing.T) {
	if _, err := NewSampler([]Session{{ID: "x", Calls: make([]Call, 2)}}, 1, 1); err == nil {
		t.Fatal("expected error")
	}
	if _, err := NewSampler(nil, 1, 1); err == nil {
		t.Fatal("expected error")
	}
}

func TestPlanUnknownClass(t *testing.T) {
	if _, err := lib(t).Plan(Call{Class: "nonesuch", WorkMs: 100}, 1, "s"); err == nil {
		t.Fatal("expected error")
	}
}

func TestPlanHostInfraTiny(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "host_infra", WorkMs: 100, DurMs: 100}, 1, "s")
	if len(ps) != 1 || ps[0].Cmd != "sleep 0.1" {
		t.Fatalf("%v", ps)
	}
}

func TestPlanZeroWork(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 0}, 1, "s")
	if len(ps) != 1 || ps[0].Cmd != "pytest -q a" {
		t.Fatalf("%v", ps)
	}
}

// runJoined runs a JoinPlan script under bash in a scratch dir and returns its exit code.
func runJoined(t *testing.T, script string) int {
	t.Helper()
	rc, _ := runJoinedErr(t, script)
	return rc
}

// runJoinedErr is runJoined plus the script's stderr.
func runJoinedErr(t *testing.T, script string) (int, string) {
	t.Helper()
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = t.TempDir()
	var stderr strings.Builder
	cmd.Stderr = &stderr
	rc := runCmd(t, cmd)
	return rc, stderr.String()
}

func runCmd(t *testing.T, cmd *exec.Cmd) int {
	t.Helper()
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ee):
		return ee.ExitCode()
	}
	t.Fatalf("running joined script: %v", err)
	return -1
}

func TestJoinPlanRunsAllStepsExitsZero(t *testing.T) {
	dir := t.TempDir()
	steps := []Planned{
		{Cmd: "true"},
		{Cmd: "false", Exit: 1},
		{Cmd: "sh -c 'exit 1'", Exit: 1},
		{Cmd: "cd / # a step's cd and a trailing comment stay inside its subshell"},
		{Cmd: "touch " + dir + "/ran-last"},
	}
	script, err := JoinPlan(steps, 0)
	if err != nil {
		t.Fatal(err)
	}
	if rc := runJoined(t, script); rc != 0 {
		t.Fatalf("exit %d, want 0 when every step exits as expected:\n%s", rc, script)
	}
	if _, err := os.Stat(dir + "/ran-last"); err != nil {
		t.Fatalf("last step did not run: %v", err)
	}
}

func TestJoinPlanExitsAtMismatchedStep(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		steps []Planned
		want  int
	}{
		{[]Planned{{Cmd: "false"}}, 90},
		{[]Planned{{Cmd: "true"}, {Cmd: "true", Exit: 1}}, 91},
		{[]Planned{{Cmd: "true"}, {Cmd: "false", Exit: 1}, {Cmd: "sh -c 'exit 1'"}, {Cmd: "touch " + dir + "/never"}}, 92},
	} {
		script, err := JoinPlan(tc.steps, 5000)
		if err != nil {
			t.Fatal(err)
		}
		if rc := runJoined(t, script); rc != tc.want {
			t.Fatalf("exit %d, want %d:\n%s", rc, tc.want, script)
		}
	}
	if _, err := os.Stat(dir + "/never"); err == nil {
		t.Fatal("a step after the failing one ran")
	}
}

func TestJoinPlanStepCodeCapped(t *testing.T) {
	steps := make([]Planned, 50)
	for i := range steps {
		steps[i] = Planned{Cmd: "true"}
	}
	steps[49].Exit = 1
	script, err := JoinPlan(steps, 0)
	if err != nil {
		t.Fatal(err)
	}
	if rc := runJoined(t, script); rc != maxStepExit {
		t.Fatalf("exit %d, want the capped %d", rc, maxStepExit)
	}
	if k, ok := FailedStep(maxStepExit); !ok || k != maxStepExit-stepExitBase {
		t.Fatalf("FailedStep(%d) = %d %v", maxStepExit, k, ok)
	}
	if k, ok := FailedStep(92); !ok || k != 2 {
		t.Fatalf("FailedStep(92) = %d %v", k, ok)
	}
	for _, c := range []int32{0, 1, 89, 126, 137} {
		if _, ok := FailedStep(c); ok {
			t.Fatalf("FailedStep(%d) claims a step", c)
		}
	}
}

func TestJoinPlanChainTailIsFinalSleep(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 1, Class: "test", WorkMs: 3000, DurMs: 60123, Chain: true}, 1, "s")
	tail := ps[len(ps)-1].SleepAfterMs
	script, err := JoinPlan(ps, tail)
	if err != nil {
		t.Fatal(err)
	}
	// ms precision: a 57.123 s tail is slept as 57.123, not rounded to a tenth.
	want := "\nsleep 57.123\nexit 0\n"
	if tail != 57123 {
		t.Fatalf("tail %d, want 57123", tail)
	}
	if !strings.HasSuffix(script, want) {
		t.Fatalf("script does not end with %q:\n%s", want, script)
	}
	script, _ = JoinPlan(ps, 0)
	if strings.Contains(script, "\nsleep ") || !strings.HasSuffix(script, "\nexit 0\n") {
		t.Fatalf("no-tail script has a sleep or lacks exit 0:\n%s", script)
	}
	start := time.Now()
	s, _ := JoinPlan([]Planned{{Cmd: "true"}}, 300)
	if rc := runJoined(t, s); rc != 0 || time.Since(start) < 290*time.Millisecond {
		t.Fatalf("exit %d after %v, want 0 after the 0.3 s tail", rc, time.Since(start))
	}
}

func TestJoinPlanHostInfraSleepInside(t *testing.T) {
	l := lib(t)
	ps := plan(t, l, Call{I: 3, Class: "host_infra", WorkMs: 4000, DurMs: 4000}, 1, "s")
	script, err := JoinPlan(ps, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(script, "(\nsleep 2.0\n); __rc=$?; [ \"$__rc\" -eq 0 ] || { echo \"E15_FAILED_STEP=0 RC=$__rc\" >&2; exit 90; }\n") {
		t.Fatalf("host_infra stand-in sleep is not the script's first step:\n%s", script)
	}
	// every planned step is in the script: singles once, a run of identical steps as one loop
	n := 0
	for k := 0; k < len(ps); {
		r := 1
		for k+r < len(ps) && ps[k+r].Cmd == ps[k].Cmd && ps[k+r].Exit == ps[k].Exit {
			r++
		}
		if r > 1 && !strings.Contains(script, fmt.Sprintf("for __i in $(seq %d); do (\n%s\n)", r, ps[k].Cmd)) {
			t.Fatalf("run of %d x %q is not one loop:\n%s", r, ps[k].Cmd, script)
		}
		n++
		k += r
	}
	if c := strings.Count(script, "__rc=$?"); c != n {
		t.Fatalf("%d checks in the script, want %d (singles and loops)", c, n)
	}
}

func TestJoinPlanDeterministic(t *testing.T) {
	l := lib(t)
	c := Call{I: 2, Class: "opaque", WorkMs: 5000, DurMs: 9000, Chain: true}
	p1, p2 := plan(t, l, c, 9, "s"), plan(t, l, c, 9, "s")
	a, _ := JoinPlan(p1, p1[len(p1)-1].SleepAfterMs)
	b, _ := JoinPlan(p2, p2[len(p2)-1].SleepAfterMs)
	if a != b {
		t.Fatal("differs")
	}
	if _, err := JoinPlan(nil, 0); err == nil {
		t.Fatal("empty plan joined")
	}
}

func TestJoinPlanMarkerPastTheCap(t *testing.T) {
	steps := make([]Planned, 45)
	for i := range steps {
		steps[i] = Planned{Cmd: "true"}
	}
	steps[40] = Planned{Cmd: "sh -c 'exit 3'"}
	script, _ := JoinPlan(steps, 0)
	rc, stderr := runJoinedErr(t, script)
	if rc != maxStepExit {
		t.Fatalf("exit %d, want the capped %d", rc, maxStepExit)
	}
	k, frc, ok := ParseFailedMarker([]byte(stderr))
	if !ok || k != 40 || frc != 3 {
		t.Fatalf("marker step %d rc %d ok %v from stderr %q, want step 40 rc 3", k, frc, ok, stderr)
	}
}

func TestJoinPlanMarkerSignal(t *testing.T) {
	script, _ := JoinPlan([]Planned{{Cmd: "true"}, {Cmd: "kill -9 $BASHPID"}}, 0)
	rc, stderr := runJoinedErr(t, script)
	k, frc, ok := ParseFailedMarker([]byte(stderr))
	if rc != 91 || !ok || k != 1 || frc != 137 {
		t.Fatalf("exit %d, marker step %d rc %d ok %v (%q), want 91 and step 1 rc 137 (128+SIGKILL)", rc, k, frc, ok, stderr)
	}
}

func TestParseFailedMarker(t *testing.T) {
	for _, tc := range []struct {
		in    string
		k, rc int
		ok    bool
	}{
		{"noise\nE15_FAILED_STEP=7 RC=2\n", 7, 2, true},
		{"E15_FAILED_STEP=1 RC=1\nE15_FAILED_STEP=9 RC=143\n", 9, 143, true}, // the last wins
		{"some command's own stderr\n", 0, 0, false},
		{"", 0, 0, false},
	} {
		k, rc, ok := ParseFailedMarker([]byte(tc.in))
		if k != tc.k || rc != tc.rc || ok != tc.ok {
			t.Fatalf("%q: got %d %d %v", tc.in, k, rc, ok)
		}
	}
}

// --- repeated steps under the guest frame limit -----------------------------------------------

func TestJoinPlanCompressesIdenticalRun(t *testing.T) {
	steps := make([]Planned, 124)
	for i := range steps {
		steps[i] = Planned{Cmd: "cd project && tar czf /tmp/x.tgz more_itertools && tar xzf /tmp/x.tgz -C /tmp # a comment"}
	}
	script, err := JoinPlan(steps, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(script) >= 1024 || strings.Count(script, "for __i in $(seq 124); do") != 1 || strings.Count(script, "tar czf") != 1 {
		t.Fatalf("%d bytes, want one 124-iteration loop under 1 KiB:\n%s", len(script), script)
	}
	// every iteration really runs, and the script still exits 0
	dir := t.TempDir()
	s, _ := JoinPlan(repeat(Planned{Cmd: "echo x >>" + dir + "/n"}, 124), 0)
	if rc := runJoined(t, s); rc != 0 {
		t.Fatalf("exit %d:\n%s", rc, s)
	}
	if b, _ := os.ReadFile(dir + "/n"); strings.Count(string(b), "x") != 124 {
		t.Fatalf("%d iterations ran, want 124", strings.Count(string(b), "x"))
	}
}

func repeat(p Planned, n int) []Planned {
	out := make([]Planned, n)
	for i := range out {
		out[i] = p
	}
	return out
}

func TestJoinPlanCompressesOnlyRuns(t *testing.T) {
	var steps []Planned
	steps = append(steps, Planned{Cmd: "sleep 0"})                      // single
	steps = append(steps, repeat(Planned{Cmd: "true"}, 3)...)           // run of 3
	steps = append(steps, Planned{Cmd: "true", Exit: 1})                // same Cmd, other Exit: not part of the run
	steps = append(steps, repeat(Planned{Cmd: "false", Exit: 1}, 2)...) // run of 2
	steps = append(steps, Planned{Cmd: "true"})                         // single
	script, _ := JoinPlan(steps, 0)
	if n := strings.Count(script, "for __i in"); n != 2 {
		t.Fatalf("%d loops, want 2:\n%s", n, script)
	}
	if !strings.Contains(script, "for __i in $(seq 3); do") || !strings.Contains(script, "for __i in $(seq 2); do") {
		t.Fatalf("loops are not the 3- and 2-runs:\n%s", script)
	}
	if n := strings.Count(script, "__rc=$?"); n != 5 {
		t.Fatalf("%d checks, want 5 (3 singles, 2 loops):\n%s", n, script)
	}
	// step 4 ("true" expected 1) fails: index after the single and the 3-run
	rc, stderr := runJoinedErr(t, script)
	k, frc, ok := ParseFailedMarker([]byte(stderr))
	if rc != 94 || !ok || k != 4 || frc != 0 {
		t.Fatalf("exit %d marker %d/%d/%v (%q), want 94 and step 4 rc 0", rc, k, frc, ok, stderr)
	}
}

func TestJoinPlanLoopFailureStepIndex(t *testing.T) {
	// K0 = 2 (two single steps first); iteration 50 of the loop fails with rc 7, so the failing
	// step is K0+49 = 51 (exit capped at 125). A counter file decides which iteration fails.
	dir := t.TempDir()
	cmd := "n=$(cat " + dir + "/c 2>/dev/null || echo 0); n=$((n+1)); echo $n >" + dir + "/c; [ $n -ne 50 ] || exit 7"
	steps := append([]Planned{{Cmd: "true"}, {Cmd: "true"}}, repeat(Planned{Cmd: cmd}, 60)...)
	script, _ := JoinPlan(steps, 0)
	if strings.Count(script, "for __i in $(seq 60)") != 1 {
		t.Fatalf("not one 60-iteration loop:\n%s", script)
	}
	rc, stderr := runJoinedErr(t, script)
	k, frc, ok := ParseFailedMarker([]byte(stderr))
	if rc != maxStepExit || !ok || k != 51 || frc != 7 {
		t.Fatalf("exit %d marker %d/%d/%v (%q), want 125 and step 51 rc 7", rc, k, frc, ok, stderr)
	}
	if fk, frcp, ok := failedFromExit(int32(rc), []byte(stderr)); !ok || fk != 51 || frcp == nil || *frcp != 7 {
		t.Fatalf("failedFromExit %d %v %v", fk, frcp, ok)
	}
	// below the cap the loop's exit code is per iteration too: K0=0, iteration 3 -> step 2 -> 92
	os.Remove(dir + "/c")
	cmd3 := "n=$(cat " + dir + "/c 2>/dev/null || echo 0); n=$((n+1)); echo $n >" + dir + "/c; [ $n -ne 3 ]"
	s3, _ := JoinPlan(repeat(Planned{Cmd: cmd3}, 5), 0)
	rc, stderr = runJoinedErr(t, s3)
	if fk, frcp, ok := failedFromExit(int32(rc), []byte(stderr)); rc != 92 || !ok || fk != 2 || frcp == nil || *frcp != 1 {
		t.Fatalf("exit %d failedFromExit %d %v %v (%q), want 92 step 2 rc 1", rc, fk, frcp, ok, stderr)
	}
}
