package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Scan is the memory-pressure point's data scan (SPEC §10.3, mem512): when Cmd is set, the joined
// script of every recorded call whose class is in Classes opens with ONE scan step -- once per
// call, however many invocations the call's plan repeats. Zero value: off (scripts unchanged).
type Scan struct {
	Cmd     string
	Classes map[string]bool
}

// ParseScan builds a Scan from --scan-cmd and --scan-classes (comma-separated). Both empty: off.
// One without the other is an error.
func ParseScan(cmd, classes string) (Scan, error) {
	var names []string
	for _, c := range strings.Split(classes, ",") {
		if c = strings.TrimSpace(c); c != "" {
			names = append(names, c)
		}
	}
	switch {
	case cmd == "" && classes == "":
		return Scan{}, nil
	case cmd == "" || len(names) == 0:
		return Scan{}, errors.New("--scan-cmd and --scan-classes go together (both set, or neither)")
	}
	s := Scan{Cmd: cmd, Classes: map[string]bool{}}
	for _, c := range names {
		s.Classes[c] = true
	}
	return s, nil
}

// For returns the scan command for a call of class cls, or "" when that call carries none.
func (s Scan) For(cls string) string {
	if s.Cmd == "" || !s.Classes[cls] {
		return ""
	}
	return s.Cmd
}

// Check refuses a scan class that is neither in the library nor a stand-in class: a typo would
// otherwise silently scan nothing.
func (s Scan) Check(l *Library) error {
	var bad []string
	for c := range s.Classes {
		if len(l.Classes[c]) == 0 && !isStandinClass(c) {
			bad = append(bad, c)
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("--scan-classes: not a library or stand-in class: %s", strings.Join(bad, ", "))
	}
	return nil
}

// scanExit is the joined script's exit code when its scan step fails (below stepExitBase, so it
// never names a numbered step); scanStep is failed_step's value for it ("scan" in calls.jsonl).
const (
	scanExit = 89
	scanStep = stepID(-1)
)

// JoinPlanScan is JoinPlan with the scan step first when scan is non-empty:
//
//	( SCAN ); __rc=$?; [ "$__rc" -eq 0 ] || { echo "E15_FAILED_STEP=scan RC=$__rc" >&2; exit 89; }
//
// The numbered steps, their exit codes, the run-length loops and the chain tail are unchanged.
func JoinPlanScan(steps []Planned, tailMs int64, scan string) (string, error) {
	s, err := JoinPlan(steps, tailMs)
	if err != nil || scan == "" {
		return s, err
	}
	return fmt.Sprintf("(\n%s\n); __rc=$?; [ \"$__rc\" -eq 0 ] || { echo \"%sscan RC=$__rc\" >&2; exit %d; }\n",
		scan, failedMarker, scanExit) + s, nil
}

var scanMarkerRE = regexp.MustCompile(`E15_FAILED_STEP=scan RC=(\d+)`)

// ParseScanMarker reports the scan step's failure marker in a stderr tail and its status.
func ParseScanMarker(tail []byte) (step stepID, rc int, ok bool) {
	all := scanMarkerRE.FindAllSubmatch(tail, -1)
	if len(all) == 0 {
		return 0, 0, false
	}
	r, err := strconv.Atoi(string(all[len(all)-1][1]))
	if err != nil {
		return 0, 0, false
	}
	return scanStep, r, true
}

// stepID is a call record's failed_step: a step index from 0, or scanStep, written as "scan".
type stepID int

func (k stepID) MarshalJSON() ([]byte, error) {
	if k == scanStep {
		return []byte(`"scan"`), nil
	}
	return json.Marshal(int(k))
}

func (k *stepID) UnmarshalJSON(b []byte) error {
	if string(b) == `"scan"` {
		*k = scanStep
		return nil
	}
	var n int
	if err := json.Unmarshal(b, &n); err != nil {
		return err
	}
	*k = stepID(n)
	return nil
}
