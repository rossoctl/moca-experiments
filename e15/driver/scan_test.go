package main

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// --- the mem512 data scan (SPEC §10.3): one scan step per recorded call of a listed class --------

const testScan = "cat /workspace/data.bin >/dev/null"

func scanFor(classes ...string) Scan {
	s, err := ParseScan(testScan, strings.Join(classes, ","))
	if err != nil {
		panic(err)
	}
	return s
}

func TestParseScan(t *testing.T) {
	if s, err := ParseScan("", ""); err != nil || s.Cmd != "" || s.For("read") != "" {
		t.Fatalf("off: %+v %v", s, err)
	}
	for _, tc := range [][2]string{{testScan, ""}, {"", "read"}, {testScan, ",,"}} {
		if _, err := ParseScan(tc[0], tc[1]); err == nil {
			t.Fatalf("%q %q accepted", tc[0], tc[1])
		}
	}
	s := scanFor("read", "test")
	if s.For("read") != testScan || s.For("test") != testScan || s.For("vcs") != "" {
		t.Fatalf("%+v", s)
	}
}

func TestScanClassesMustBeKnown(t *testing.T) {
	lib := testLib(nil, "read", "vcs")
	if err := scanFor("read", "build").Check(lib); err != nil { // build: a stand-in class
		t.Fatal(err)
	}
	if err := scanFor("read", "nosuch").Check(lib); err == nil || !strings.Contains(err.Error(), "nosuch") {
		t.Fatalf("unknown class accepted: %v", err)
	}
}

func TestJoinPlanScanOff(t *testing.T) {
	ps := []Planned{{Cmd: "a"}, {Cmd: "b", Exit: 1}}
	a, _ := JoinPlan(ps, 300)
	b, _ := JoinPlanScan(ps, 300, "")
	if a != b || strings.Contains(a, "scan") {
		t.Fatalf("scan off must leave the script byte-identical:\n%s\n---\n%s", a, b)
	}
}

func TestJoinPlanScanPrependedOnce(t *testing.T) {
	// 3 distinct steps, then a 50-step run (RLE loop), then a chain tail
	ps := append([]Planned{{Cmd: "a"}, {Cmd: "b"}}, repeat(Planned{Cmd: "c"}, 50)...)
	s, err := JoinPlanScan(ps, ps[len(ps)-1].SleepAfterMs, testScan)
	if err != nil {
		t.Fatal(err)
	}
	want := "(\n" + testScan + "\n); __rc=$?; [ \"$__rc\" -eq 0 ] || { echo \"E15_FAILED_STEP=scan RC=$__rc\" >&2; exit 89; }\n"
	if !strings.HasPrefix(s, want) {
		t.Fatalf("script does not open with the scan step:\n%s", s)
	}
	if strings.Count(s, testScan) != 1 || strings.Count(s, "for __i in $(seq 50); do") != 1 {
		t.Fatalf("want one scan and one 50-iteration loop:\n%s", s)
	}
	// the rest is exactly the unscanned script: step indices and exit codes unchanged
	plain, _ := JoinPlan(ps, 0)
	if strings.TrimPrefix(s, want) != plain {
		t.Fatalf("scan changed the steps:\n%s", s)
	}
}

func TestJoinPlanScanRunsOncePerCall(t *testing.T) {
	dir := t.TempDir()
	scan := "echo s >>" + dir + "/scans"
	s, _ := JoinPlanScan(repeat(Planned{Cmd: "echo x >>" + dir + "/n"}, 7), 0, scan)
	if rc := runJoined(t, s); rc != 0 {
		t.Fatalf("exit %d:\n%s", rc, s)
	}
	if n := countFile(t, dir+"/scans", "s"); n != 1 {
		t.Fatalf("scan ran %d times, want 1", n)
	}
	if n := countFile(t, dir+"/n", "x"); n != 7 {
		t.Fatalf("%d steps ran, want 7", n)
	}
}

func TestJoinPlanScanFailureExits89(t *testing.T) {
	dir := t.TempDir()
	s, _ := JoinPlanScan([]Planned{{Cmd: "echo x >>" + dir + "/n"}}, 0, "exit 3")
	rc, stderr := runJoinedErr(t, s)
	if rc != scanExit || scanExit != 89 || !strings.Contains(stderr, "E15_FAILED_STEP=scan RC=3") {
		t.Fatalf("rc %d stderr %q", rc, stderr)
	}
	if countFile(t, dir+"/n", "x") != 0 {
		t.Fatal("a step ran after the scan failed")
	}
	if k, rc, ok := ParseScanMarker([]byte("noise\nE15_FAILED_STEP=scan RC=3\n")); !ok || k != scanStep || rc != 3 {
		t.Fatalf("ParseScanMarker: %v %v %v", k, rc, ok)
	}
}

func TestValidatePlansFrameIncludesScan(t *testing.T) {
	// a call whose joined script fits the frame alone but not with a long scan command
	lib := testLib(nil, "q")
	lib.Classes["q"][0].Cmd = strings.Repeat("q", 20<<10)
	ss := []Session{sess("s", "u", 20, "q", "q", "q")}
	if err := validatePlans(ss, lib, 1, Scan{}); err != nil {
		t.Fatalf("fixture must fit without the scan: %v", err)
	}
	big, _ := ParseScan(strings.Repeat("z", 12<<10), "q")
	if err := validatePlans(ss, lib, 1, big); err == nil {
		t.Fatal("the frame check ignored the scan step")
	}
	if err := validatePlans(ss, lib, 1, scanFor("other")); err != nil {
		t.Fatalf("an unlisted class carries no scan: %v", err)
	}
}

func TestScanOnlyListedClassesInRun(t *testing.T) {
	client, f := newFake(t)
	cfg := baseCfg()
	cfg.Window = 300 * time.Millisecond
	cfg.Scan = scanFor("a")
	res := run(t, cfg, []Session{sess("s", "u", 20, "a", "b", "a", "b")}, testLib(nil, "a", "b"), client)
	if res.err != nil || len(res.calls) < 3 {
		t.Fatal(res.err, len(res.calls))
	}
	for _, e := range f.byKey()["e15-t-0-0"] {
		scanned := strings.Contains(e.cmd, testScan)
		isA := strings.Contains(e.cmd, "(\na\n)")
		if scanned != isA || strings.Count(e.cmd, testScan) > 1 {
			t.Fatalf("class a scanned %v, class b scanned %v:\n%s", isA && scanned, !isA && scanned, e.cmd)
		}
	}
	for _, c := range res.calls {
		if c.Status != "ok" {
			t.Fatalf("%+v", c)
		}
	}
}

func TestScanFailureRecordedAsScanStep(t *testing.T) {
	client, _ := newFake(t)
	cfg := baseCfg()
	cfg.Window = 100 * time.Millisecond
	cfg.Scan, _ = ParseScan("exit1", "a") // the fake's exit1 exits 1
	res := run(t, cfg, []Session{sess("s", "u", 20, "a", "a", "a")}, testLib(nil, "a"), client)
	if res.err != nil || len(res.calls) == 0 {
		t.Fatal(res.err, len(res.calls))
	}
	c := res.calls[0]
	if c.Status != "err" || c.Cause != "exit_mismatch" || c.Exit == nil || *c.Exit != 89 ||
		c.FailedStep == nil || *c.FailedStep != scanStep || c.FailedRC == nil || *c.FailedRC != 1 || !strings.Contains(c.Msg, "scan") {
		t.Fatalf("call %+v (failed_step %v failed_rc %v)", c, c.FailedStep, c.FailedRC)
	}
	b, _ := json.Marshal(c)
	if !strings.Contains(string(b), `"failed_step":"scan"`) {
		t.Fatalf("calls.jsonl line %s, want failed_step \"scan\"", b)
	}
	b, _ = json.Marshal(callRecord{FailedStep: ptr(stepID(4))})
	if !strings.Contains(string(b), `"failed_step":4`) {
		t.Fatalf("a numbered step must stay a number: %s", b)
	}
}

func TestScanFlags(t *testing.T) {
	env := func(string) string { return "tok" }
	var sb strings.Builder
	for _, args := range [][]string{
		{"--scan-cmd", testScan},
		{"--scan-classes", "read"},
	} {
		sb.Reset()
		base := []string{"--corpus", "testdata/corpus-small.jsonl", "--library", "testdata/library.json", "--n", "1", "--run-id", "r", "--out", t.TempDir()}
		if rc := realMain(append(base, args...), env, &sb); rc != 2 || !strings.Contains(sb.String(), "scan") {
			t.Fatalf("%v: rc %d %q", args, rc, sb.String())
		}
	}
	sb.Reset()
	base := []string{"--corpus", "testdata/corpus-small.jsonl", "--library", "testdata/library.json", "--n", "1", "--run-id", "r", "--out", t.TempDir()}
	if rc := realMain(append(base, "--scan-cmd", testScan, "--scan-classes", "read,nosuch"), env, &sb); rc != 2 || !strings.Contains(sb.String(), "nosuch") {
		t.Fatalf("unknown scan class: rc %d %q", rc, sb.String())
	}
}

func ptr[T any](v T) *T { return &v }

func countFile(t *testing.T, path, s string) int {
	t.Helper()
	b, err := readFileOrEmpty(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(b), s)
}

func readFileOrEmpty(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return b, err
}

func TestStandinClassesShared(t *testing.T) {
	for _, c := range []string{"host_infra", "opaque", "build"} {
		if !isStandinClass(c) {
			t.Fatalf("%s is a stand-in class", c)
		}
	}
	if isStandinClass("read") {
		t.Fatal("read is not a stand-in class")
	}
	// Scan.Check accepts exactly the stand-in classes the planner accepts without a library entry
	lib := testLib(nil, "q")
	for _, c := range []string{"host_infra", "opaque", "build", "nosuch"} {
		_, perr := lib.Plan(Call{Class: c, WorkMs: 100, DurMs: 100}, 1, "s")
		cerr := scanFor(c).Check(lib)
		if (perr == nil) != (cerr == nil) {
			t.Fatalf("%s: Plan err %v, Check err %v", c, perr, cerr)
		}
	}
}
