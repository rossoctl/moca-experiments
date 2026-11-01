package main

import (
	"errors"
	"fmt"
	"testing"
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
