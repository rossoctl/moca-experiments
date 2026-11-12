package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
)

// callRecord is one calls.jsonl line: one recorded Call, sent as ONE Exec (its planned invocations
// joined into one guest script by JoinPlan; execs is 1 once sent, 0 when never started).
// session is the replay instance (its workspace_key); trace and provider name the corpus session.
// t_ms is the monotonic offset of the call's first send from the start of the run.
type callRecord struct {
	Ts           string  `json:"ts"`
	TMs          float64 `json:"t_ms"`
	Session      string  `json:"session"`
	Trace        string  `json:"trace"`
	Provider     string  `json:"provider"`
	Call         int     `json:"call"`
	Class        string  `json:"class"`
	Execs        int     `json:"execs"`
	PlannedDurMs int64   `json:"planned_dur_ms"`
	PlannedGapMs int64   `json:"planned_gap_ms"`
	TailMs       int64   `json:"tail_ms"` // always 0: a chain's idle tail runs inside its Exec, before End (kept for the analysis formulas)
	ObservedMs   float64 `json:"observed_ms"`
	Status       string  `json:"status"`
	Cause        string  `json:"cause"`
	Exit         *int32  `json:"exit"`
	ExpectedExit int32   `json:"expected_exit"`
	FailedStep   *stepID `json:"failed_step,omitempty"` // exit_mismatch: the joined script's failing step (from 0), or "scan" (exit 89)
	FailedRC     *int    `json:"failed_rc,omitempty"`   // that step's own exit status (128+sig when killed), from the script's stderr marker
	InWindow     bool    `json:"in_window"`
	Msg          string  `json:"msg,omitempty"`
}

// sessionRecord is one sessions.jsonl line, over the session's in-window calls only.
type sessionRecord struct {
	Session     string  `json:"session"`
	Trace       string  `json:"trace"`
	Provider    string  `json:"provider"`
	WindowCalls int     `json:"window_calls"`
	PlannedMs   int64   `json:"planned_ms"`
	ObservedMs  float64 `json:"observed_ms"`
}

// cpuHeader is driver-cpu.jsonl's first line: the A2 denominator for the analysis.
type cpuHeader struct {
	Header     bool   `json:"header"`
	NumCPU     int    `json:"num_cpu"`
	GOMAXPROCS int    `json:"gomaxprocs"`
	GOOS       string `json:"goos"`
	GOARCH     string `json:"goarch"`
	// T0Epoch is the wall clock (Unix seconds) at the driver's t0, the origin of every t.
	T0Epoch float64 `json:"t0_epoch"`
}

// cpuFooter is driver-cpu.jsonl's last line when --end-session-exec is on.
type cpuFooter struct {
	Footer            bool  `json:"footer"`
	EndSessionsSent   int64 `json:"end_sessions_sent"`
	EndSessionsOK     int64 `json:"end_sessions_ok"`
	EndSessionsFailed int64 `json:"end_sessions_failed"`
	// E16 --end-session-defer only (omitted when 0, so E15 footers are unchanged)
	EndSessionsDeferred int64 `json:"end_sessions_deferred,omitempty"`
	// E16 --end-session-defer only: failed end-session Execs by "cause: message" (omitted when none)
	EndSessionFailCauses map[string]int64 `json:"end_session_fail_causes,omitempty"`
}

// cpuRecord is one driver-cpu.jsonl line: cumulative process CPU at t seconds (monotonic) since
// the start of the run.
type cpuRecord struct {
	T       float64 `json:"t"`
	UtimeMs int64   `json:"utime_ms"`
	StimeMs int64   `json:"stime_ms"`
}

// bufSize is large enough that a whole rung's records normally stay in memory until the final
// flush: a write syscall per call would be driver cost inside the measured window (exec-driver's
// rationale). bufio still flushes if a buffer fills, which costs a syscall, not a record.
const bufSize = 8 << 20

type jsonl struct {
	mu sync.Mutex
	w  *bufio.Writer
}

func (j *jsonl) write(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if _, err := j.w.Write(append(b, '\n')); err != nil {
		return err
	}
	return nil
}

// Recorder holds one shared buffered writer per output file.
type Recorder struct {
	calls, sessions, cpu *jsonl
	errMu                sync.Mutex
	err                  error
}

func NewRecorder(calls, sessions, cpu io.Writer) *Recorder {
	mk := func(w io.Writer) *jsonl { return &jsonl{w: bufio.NewWriterSize(w, bufSize)} }
	return &Recorder{calls: mk(calls), sessions: mk(sessions), cpu: mk(cpu)}
}

func (r *Recorder) keep(err error) {
	if err != nil {
		r.errMu.Lock()
		if r.err == nil {
			r.err = err
		}
		r.errMu.Unlock()
	}
}

func (r *Recorder) Call(c callRecord)       { r.keep(r.calls.write(c)) }
func (r *Recorder) Session(s sessionRecord) { r.keep(r.sessions.write(s)) }
func (r *Recorder) CPU(c cpuRecord)         { r.keep(r.cpu.write(c)) }
func (r *Recorder) CPUHeader(h cpuHeader)   { r.keep(r.cpu.write(h)) }
func (r *Recorder) CPUFooter(f cpuFooter)   { r.keep(r.cpu.write(f)) }

// Flush writes out every buffer and returns the first write error seen during the run.
func (r *Recorder) Flush() error {
	var errs []error
	for _, j := range []*jsonl{r.calls, r.sessions, r.cpu} {
		j.mu.Lock()
		errs = append(errs, j.w.Flush())
		j.mu.Unlock()
	}
	r.errMu.Lock()
	errs = append(errs, r.err)
	r.errMu.Unlock()
	return errors.Join(errs...)
}

// clkTck is USER_HZ, which is 100 on every Linux architecture the rig runs (x86_64, arm64);
// reading it needs sysconf, i.e. cgo, which this module avoids.
const clkTck = 100

// parseProcStat returns utime and stime in ms from a /proc/<pid>/stat line. The comm field may
// hold spaces and parentheses, so fields are counted after the LAST ')'.
func parseProcStat(line string) (utimeMs, stimeMs int64, err error) {
	i := strings.LastIndexByte(line, ')')
	if i < 0 {
		return 0, 0, fmt.Errorf("proc stat: no ')' in %q", line)
	}
	f := strings.Fields(line[i+1:])
	// f[0] is field 3 (state); utime and stime are fields 14 and 15.
	if len(f) < 13 {
		return 0, 0, fmt.Errorf("proc stat: %d fields after comm", len(f))
	}
	u, err := strconv.ParseInt(f[11], 10, 64)
	if err != nil {
		return 0, 0, fmt.Errorf("proc stat utime: %w", err)
	}
	s, err := strconv.ParseInt(f[12], 10, 64)
	if err != nil {
		return 0, 0, fmt.Errorf("proc stat stime: %w", err)
	}
	return u * 1000 / clkTck, s * 1000 / clkTck, nil
}
