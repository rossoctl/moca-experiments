package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"
)

// deferRun: N slots of long sessions (1 s offsets) that the run's end stops mid-gap, plus one slot
// whose short session ends on its own mid-run (natural end).
func deferRun(t *testing.T, deferOn bool, rate int) (result, *fake, *Replayer) {
	t.Helper()
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.N, cfg.Window, cfg.Grace, cfg.EndSessionExec = 12, 300*time.Millisecond, 200*time.Millisecond, true
	cfg.EndSessionDefer, cfg.EndSessionRate = deferOn, rate
	ss := []Session{sess("long", "u", 1000, "q", "q", "q", "q")}
	r, do := newReplay(t, cfg, ss, testLib(nil, "q"), client)
	return do(), f, r
}

func endSessions(f *fake) []fakeExec {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fakeExec
	for _, e := range f.execs {
		if e.cmd == EndSessionCommand {
			out = append(out, e)
		}
	}
	return out
}

func TestEndSessionDeferAfterGraceAndPaced(t *testing.T) {
	res, f, r := deferRun(t, true, 20)
	if res.err != nil {
		t.Fatal(res.err)
	}
	es := endSessions(f)
	if len(es) != 12 {
		t.Fatalf("got %d end-session Execs, want 12 (one per slot)", len(es))
	}
	first, last := es[0].recv, es[0].recv
	for _, e := range es {
		if e.recv.Before(r.graceEnd) {
			t.Fatalf("deferred end-session sent at %v, before graceEnd %v", e.recv.Sub(r.t0), r.graceEnd.Sub(r.t0))
		}
		if e.recv.Before(first) {
			first = e.recv
		}
		if e.recv.After(last) {
			last = e.recv
		}
	}
	// 12 starts at 20/s span >= 11 intervals of 50 ms (allow scheduler slack below)
	if span := last.Sub(first); span < 500*time.Millisecond {
		t.Fatalf("12 deferred sends spanned %v, want >= 550 ms at 20/s (rate exceeded)", span)
	}
	// never more than rate+1 starts inside any 1 s window
	for _, a := range es {
		n := 0
		for _, b := range es {
			if !b.recv.Before(a.recv) && b.recv.Before(a.recv.Add(time.Second)) {
				n++
			}
		}
		if n > 21 {
			t.Fatalf("%d starts within 1 s, over the rate", n)
		}
	}
	lastRow := res.cpuRaw[len(res.cpuRaw)-1]
	if lastRow["end_sessions_deferred"].(float64) != 12 || lastRow["end_sessions_ok"].(float64) != 12 {
		t.Fatalf("footer %v, want 12 deferred, 12 ok", lastRow)
	}
}

func TestEndSessionDeferNaturalEndsUnaffected(t *testing.T) {
	// one slot of short sessions: several end on their own mid-run (sent at once, before the next
	// session), only the one live at the run's end is deferred
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window, cfg.EndSessionExec, cfg.EndSessionDefer = 250*time.Millisecond, true, true
	r, do := newReplay(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q", "q", "q")}, testLib(nil, "q"), client)
	res := do()
	if res.err != nil {
		t.Fatal(res.err)
	}
	by := f.byKey()
	natural, deferred := 0, 0
	for k, ex := range by {
		end := ex[len(ex)-1]
		if end.cmd != EndSessionCommand {
			t.Fatalf("%s: last Exec is not the end-session", k)
		}
		if end.recv.Before(r.end) {
			natural++
		} else {
			deferred++
			if end.recv.Before(r.graceEnd) {
				t.Fatalf("%s: run-end end-session sent before graceEnd", k)
			}
		}
	}
	if natural < 2 || deferred != 1 {
		t.Fatalf("natural=%d deferred=%d, want >= 2 natural (sent at once) and 1 deferred", natural, deferred)
	}
}

func TestEndSessionDeferOffIsUnchanged(t *testing.T) {
	// flag off: the run-end end-session is sent at once (before graceEnd), and the footer has no
	// end_sessions_deferred key, byte-for-byte the E15 footer shape
	res, f, r := deferRun(t, false, 0)
	if res.err != nil {
		t.Fatal(res.err)
	}
	for _, e := range endSessions(f) {
		if !e.recv.Before(r.graceEnd) {
			t.Fatalf("flag off: end-session sent at %v, not at once", e.recv.Sub(r.t0))
		}
	}
	var b bytes.Buffer
	rec := NewRecorder(&b, &b, &b)
	rec.CPUFooter(cpuFooter{Footer: true, EndSessionsSent: 1, EndSessionsOK: 1})
	if err := rec.Flush(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(b.String(), "deferred") || !strings.Contains(b.String(), `{"footer":true,"end_sessions_sent":1,"end_sessions_ok":1,"end_sessions_failed":0}`) {
		t.Fatalf("flag-off footer changed: %q", b.String())
	}
	_ = context.Background
}

func TestEndSessionDeferRecordsFailureCauses(t *testing.T) {
	client, f := newFake(t)
	f.failEnd = true
	cfg := baseCfg()
	cfg.N, cfg.Window, cfg.Grace, cfg.EndSessionExec, cfg.EndSessionDefer = 3, 200*time.Millisecond, 100*time.Millisecond, true, true
	_, do := newReplay(t, cfg, []Session{sess("long", "u", 1000, "q", "q", "q")}, testLib(nil, "q"), client)
	res := do()
	if res.err != nil {
		t.Fatal(res.err)
	}
	last := res.cpuRaw[len(res.cpuRaw)-1]
	fc, ok := last["end_session_fail_causes"].(map[string]any)
	if !ok || len(fc) == 0 {
		t.Fatalf("footer %v: want end_session_fail_causes", last)
	}
	var n float64
	for _, v := range fc {
		n += v.(float64)
	}
	if n != last["end_sessions_failed"].(float64) {
		t.Fatalf("causes %v sum %v != failed %v", fc, n, last["end_sessions_failed"])
	}
}
