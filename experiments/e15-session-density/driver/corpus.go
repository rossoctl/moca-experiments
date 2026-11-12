// Package main is the E15 replay driver. This file is its data layer: corpus and command-library
// loading, deterministic session sampling, and expansion of a recorded call into real commands.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"math/rand"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Call is one recorded tool call (corpus.jsonl).
type Call struct {
	I        int    `json:"i"`
	Class    string `json:"class"`
	Skeleton string `json:"skeleton"`
	DurMs    int64  `json:"dur_ms"`
	WorkMs   int64  `json:"work_ms"`
	GapMs    int64  `json:"gap_ms"`
	OffsetMs int64  `json:"offset_ms"`
	OutBytes int64  `json:"out_bytes"`
	Chain    bool   `json:"chain"`
}

// Session is one recorded session.
type Session struct {
	ID       string `json:"session"`
	User     string `json:"user"`
	Provider string `json:"provider"`
	Calls    []Call `json:"calls"`
}

// Invocation is one real command in the library.
type Invocation struct {
	ID        string `json:"id"`
	Cmd       string `json:"cmd"`
	Exit      int32  `json:"exit"`
	NominalMs int64  `json:"nominal_ms"`
	RunMs     *int64 `json:"run_ms"`
	CPUMs     *int64 `json:"cpu_ms"`
}

// Ms is the matching duration: run_ms when measured, else nominal_ms.
func (v Invocation) Ms() int64 {
	if v.RunMs != nil {
		return *v.RunMs
	}
	return v.NominalMs
}

// Library is the parsed library.json.
type Library struct {
	Version int                     `json:"version"`
	Classes map[string][]Invocation `json:"classes"`
	Standin struct {
		InterpreterClass string  `json:"interpreter_class"`
		InfraSleepFrac   float64 `json:"infra_sleep_frac"`
	} `json:"standin"`
}

// Planned is one command to send.
type Planned struct {
	Cmd          string
	Exit         int32
	SleepAfterMs int64 // chain idle tail; only ever non-zero on the last command of a chain call. JoinPlan runs it as the Exec's final sleep; the driver never sleeps it
}

// LoadCorpus reads corpus.jsonl (one session per line).
func LoadCorpus(path string) ([]Session, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []Session
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 256<<20)
	for n := 1; sc.Scan(); n++ {
		if len(sc.Bytes()) == 0 {
			continue
		}
		var s Session
		if err := json.Unmarshal(sc.Bytes(), &s); err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, n, err)
		}
		out = append(out, s)
	}
	return out, sc.Err()
}

// LoadLibrary reads library.json.
func LoadLibrary(path string) (*Library, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	l := &Library{}
	if err := json.Unmarshal(b, l); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if l.Standin.InterpreterClass == "" || len(l.Classes[l.Standin.InterpreterClass]) == 0 {
		return nil, fmt.Errorf("%s: stand-in interpreter class %q has no invocations", path, l.Standin.InterpreterClass)
	}
	return l, nil
}

const minCalls = 3

// ErrCapUnsatisfiable is returned by Sampler.Next when no session in the corpus fits under the
// per-user cap given the current live population.
var ErrCapUnsatisfiable = errors.New("sampler: no session satisfies the per-user cap")

// Sampler draws sessions without replacement (reshuffling on exhaustion), seeded, enforcing
// userCap (fraction of the live population one user may hold).
type Sampler struct {
	sessions []Session
	rng      *rand.Rand
	userCap  float64
	pool     []int // not yet drawn this cycle, in draw order
	drawn    []int // drawn this cycle
}

// NewSampler ignores sessions with fewer than 3 calls and fails if none remain.
func NewSampler(sessions []Session, seed int64, userCap float64) (*Sampler, error) {
	s := &Sampler{rng: rand.New(rand.NewSource(seed)), userCap: userCap}
	for _, x := range sessions {
		if len(x.Calls) >= minCalls {
			s.sessions = append(s.sessions, x)
		}
	}
	if len(s.sessions) == 0 {
		return nil, fmt.Errorf("sampler: no sessions with at least %d calls", minCalls)
	}
	for i := range s.sessions {
		s.pool = append(s.pool, i)
	}
	s.shuffle()
	return s, nil
}

func (s *Sampler) shuffle() {
	s.rng.Shuffle(len(s.pool), func(a, b int) { s.pool[a], s.pool[b] = s.pool[b], s.pool[a] })
}

// Next returns the next session and a start index uniform in [0, len(Calls)-3]. live maps user to
// live session count; a user at floor(userCap*n) (minimum 1) is skipped and the session stays in
// the pool for a later draw. If the pool holds no eligible session, the already-drawn sessions are
// appended to what remains and the pool is reshuffled (nothing undrawn is discarded); if still no
// session is eligible, Next returns ErrCapUnsatisfiable. The caller increments live.
func (s *Sampler) Next(live map[string]int, n int) (Session, int, error) {
	limit := int(math.Floor(s.userCap*float64(n) + 1e-9))
	if limit < 1 {
		limit = 1
	}
	pick := func() int {
		for p, idx := range s.pool {
			if live[s.sessions[idx].User] < limit {
				return p
			}
		}
		return -1
	}
	p := pick()
	if p < 0 {
		s.pool = append(s.pool, s.drawn...)
		s.drawn = s.drawn[:0]
		s.shuffle()
		if p = pick(); p < 0 {
			return Session{}, 0, ErrCapUnsatisfiable
		}
	}
	idx := s.pool[p]
	s.pool = append(s.pool[:p], s.pool[p+1:]...)
	s.drawn = append(s.drawn, idx)
	sess := s.sessions[idx]
	return sess, s.rng.Intn(len(sess.Calls) - minCalls + 1), nil
}

// callSeed is FNV-64a over: seed (8 bytes big-endian), sessionID bytes, 0x00, I (8 bytes big-endian).
func callSeed(seed int64, sessionID string, i int) int64 {
	h := fnv.New64a()
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(seed))
	h.Write(b[:])
	h.Write([]byte(sessionID))
	h.Write([]byte{0})
	binary.BigEndian.PutUint64(b[:], uint64(i))
	h.Write(b[:])
	return int64(h.Sum64())
}

type step struct {
	p     Planned
	runMs int64
}

// fill picks invocations of one class until the remainder is under 50 ms. The first pick always
// happens: if nothing fits, the shortest runs once.
func fill(invs []Invocation, work int64, rng *rand.Rand) []step {
	var out []step
	rem := work
	for len(out) == 0 || rem >= 50 {
		best := int64(-1)
		var cands []Invocation
		for _, v := range invs {
			m := v.Ms()
			if m > rem {
				continue
			}
			if m > best {
				best, cands = m, nil
			}
			if m == best {
				cands = append(cands, v)
			}
		}
		if len(cands) == 0 {
			if len(out) > 0 {
				break
			}
			short := invs[0]
			for _, v := range invs {
				if v.Ms() < short.Ms() {
					short = v
				}
			}
			out = append(out, step{Planned{Cmd: short.Cmd, Exit: short.Exit}, short.Ms()})
			break
		}
		v := cands[rng.Intn(len(cands))]
		out = append(out, step{Planned{Cmd: v.Cmd, Exit: v.Exit}, v.Ms()})
		if best <= 0 {
			break // zero-length invocation would never make progress
		}
		rem -= best
	}
	return out
}

// groupSteps reorders a call's fill steps in place so identical invocations (same Cmd and Exit)
// are contiguous, each group at its first appearance, stably. A greedy duration fill's order is
// arbitrary, so the work and the total duration are unchanged; contiguous steps let JoinPlan
// run-length encode them and keep the joined script under the guest frame limit. Deterministic.
func groupSteps(ps []Planned) {
	type key struct {
		cmd  string
		exit int32
	}
	first := map[key]int{}
	for i, p := range ps {
		if _, ok := first[key{p.Cmd, p.Exit}]; !ok {
			first[key{p.Cmd, p.Exit}] = i
		}
	}
	sort.SliceStable(ps, func(a, b int) bool {
		return first[key{ps[a].Cmd, ps[a].Exit}] < first[key{ps[b].Cmd, ps[b].Exit}]
	})
}

// Stand-in classes (SPEC §5.6): replayed without a library entry of their own. host_infra is a
// sleep plus interpreter invocations; the interpreter-stand-in classes replay the interpreter
// class for their recorded time. The one definition Plan, validatePlans and Scan.Check use.
const classHostInfra = "host_infra"

var interpStandinClasses = map[string]bool{"opaque": true, "build": true}

// isStandinClass reports whether cls is a stand-in class (needs no library entry).
func isStandinClass(cls string) bool { return cls == classHostInfra || interpStandinClasses[cls] }

// Plan expands one call into the commands to send, deterministically for (seed, sessionID, c.I).
// Classes without a library entry use the interpreter stand-in; host_infra is sleep plus
// interpreter invocations.
func (l *Library) Plan(c Call, seed int64, sessionID string) ([]Planned, error) {
	rng := rand.New(rand.NewSource(callSeed(seed, sessionID, c.I)))
	interp := l.Classes[l.Standin.InterpreterClass]
	var steps []step
	switch {
	case c.Class == classHostInfra:
		sleepMs := int64(math.Round(float64(c.WorkMs)*l.Standin.InfraSleepFrac/100)) * 100
		if sleepMs > 0 {
			steps = append(steps, step{Planned{Cmd: fmt.Sprintf("sleep %.1f", float64(sleepMs)/1000)}, sleepMs})
		}
		if rem := c.WorkMs - sleepMs; rem >= 50 || len(steps) == 0 {
			steps = append(steps, fill(interp, rem, rng)...)
		}
	case len(l.Classes[c.Class]) > 0:
		steps = fill(l.Classes[c.Class], c.WorkMs, rng)
	case interpStandinClasses[c.Class]:
		steps = fill(interp, c.WorkMs, rng)
	default:
		return nil, fmt.Errorf("plan: class %q is neither in the library nor a stand-in class", c.Class)
	}
	out := make([]Planned, len(steps))
	var sum int64
	for i, st := range steps {
		out[i] = st.p
		sum += st.runMs
	}
	// host_infra's stand-in sleep is step 0 and unlike any fill step, so first-appearance
	// grouping keeps it first.
	groupSteps(out)
	if c.Chain && len(out) > 0 {
		if tail := c.DurMs - sum; tail > 0 {
			out[len(out)-1].SleepAfterMs = tail
		}
	}
	return out, nil
}

// A joined script exits stepExitBase+k when its step k (from 0) exits other than the library
// expects, capped at maxStepExit so the code stays below the shell's 126+ range (not executable,
// not found, killed by a signal). Steps from 35 on all report maxStepExit, so the script also
// writes failedMarker ("E15_FAILED_STEP=<k> RC=<rc>") to stderr first: the exact step and its own
// status (128+sig when a signal killed it). The capped code is the fallback when no marker
// arrives.
const (
	stepExitBase = 90
	maxStepExit  = 125
)

// JoinPlan builds the ONE guest shell script that replays a recorded call (SPEC §5.3, §5.6: one
// recorded call is one command). Each step runs in its own subshell, so a step's cd, exit or
// trailing comment cannot leak into the next; the step's exit code is checked against the
// library's and the script exits stepExitBase+k at the first mismatch. A chain's idle tail
// (tailMs > 0) is the script's final sleep, so the replayed process holds its sandbox for the
// chain's whole lifetime. The script exits 0 when every step matched. host_infra's stand-in sleep
// is an ordinary step.
//
// Consecutive identical steps (same Cmd and Exit) are run-length encoded into one loop that keeps
// the per-iteration check and reports the actual step index (K0+__i-1), so the work is the same
// but the script stays under the guest agent's 32 KiB frame (MaxFrame, guestagent/protocol.go):
// Plan fills a long work_ms by repeating one short invocation, up to thousands of times.
func JoinPlan(steps []Planned, tailMs int64) (string, error) {
	if len(steps) == 0 {
		return "", errors.New("join: no steps")
	}
	var b strings.Builder
	for k := 0; k < len(steps); {
		p := steps[k]
		n := 1
		for k+n < len(steps) && steps[k+n].Cmd == p.Cmd && steps[k+n].Exit == p.Exit {
			n++
		}
		if n == 1 {
			code := min(stepExitBase+k, maxStepExit)
			fmt.Fprintf(&b, "(\n%s\n); __rc=$?; [ \"$__rc\" -eq %d ] || { echo \"%s%d RC=$__rc\" >&2; exit %d; }\n",
				p.Cmd, p.Exit, failedMarker, k, code)
		} else {
			// __k is the failing iteration's step index; its exit code is capped as for a single step.
			fmt.Fprintf(&b, "for __i in $(seq %d); do (\n%s\n); __rc=$?; [ \"$__rc\" -eq %d ] || { __k=$((%d + __i - 1)); "+
				"echo \"%s$__k RC=$__rc\" >&2; exit $((__k < %d ? %d + __k : %d)); }; done\n",
				n, p.Cmd, p.Exit, k, failedMarker, maxStepExit-stepExitBase, stepExitBase, maxStepExit)
		}
		k += n
	}
	if tailMs > 0 {
		fmt.Fprintf(&b, "sleep %.3f\n", float64(tailMs)/1000)
	}
	b.WriteString("exit 0\n")
	return b.String(), nil
}

// firecrackerWrapPrefix and firecrackerWrapSuffix are what the microVM launcher puts around
// every command before sending it (wrapCommand, remote-worker/internal/vmpool/
// launcher_firecracker.go:1089 at moca v0.9.0; both the per-Exec and the resident worker run
// through it).
const (
	firecrackerWrapPrefix = "cd /workspace\n( "
	firecrackerWrapSuffix = "\n)\n__fc_rc=$?\nsync\n(exit $__fc_rc)\n"
)

// guestRequest mirrors guestagent.Request (protocol.go at v0.9.0), which the worker sends as
// ONE JSON frame (WriteJSON: json.Marshal, payload <= MaxFrame 32 KiB; guestconn.go:105).
type guestRequest struct {
	Command       string `json:"command"`
	TimeoutS      uint32 `json:"timeout_s"`
	Streaming     bool   `json:"streaming"`
	CapBytes      int64  `json:"cap_bytes"`
	HasStdin      bool   `json:"has_stdin"`
	HostUnixNanos int64  `json:"host_unix_nanos"`
}

// guestFrameSlack covers any field this mirror lacks or a later worker adds.
const guestFrameSlack = 512

// guestFrameBytes is an upper bound on the guest Request frame payload for a joined script: the
// launcher-wrapped command JSON-encoded as the worker does (json.Marshal escapes <, >, & as six
// bytes and newlines and quotes as two), every numeric field at its widest, plus guestFrameSlack.
func guestFrameBytes(script string) int {
	b, _ := json.Marshal(guestRequest{
		Command: firecrackerWrapPrefix + script + firecrackerWrapSuffix, TimeoutS: math.MaxUint32,
		Streaming: true, CapBytes: math.MinInt64, HasStdin: true, HostUnixNanos: math.MinInt64,
	})
	return len(b) + guestFrameSlack
}

const failedMarker = "E15_FAILED_STEP="

var markerRE = regexp.MustCompile(`E15_FAILED_STEP=(\d+) RC=(\d+)`)

// ParseFailedMarker returns the step and status from the LAST failure marker in a stderr tail
// (a step's own stderr may precede it; the script writes the marker just before it exits).
func ParseFailedMarker(tail []byte) (step, rc int, ok bool) {
	all := markerRE.FindAllSubmatch(tail, -1)
	if len(all) == 0 {
		return 0, 0, false
	}
	m := all[len(all)-1]
	k, err1 := strconv.Atoi(string(m[1]))
	r, err2 := strconv.Atoi(string(m[2]))
	if err1 != nil || err2 != nil {
		return 0, 0, false
	}
	return k, r, true
}

// failedFromExit identifies a joined script's failing step: from the stderr marker when present
// (and consistent with the exit code's capped step), else from the capped exit code alone, in
// which case rc is nil.
func failedFromExit(exit int32, stderrTail []byte) (int, *int, bool) {
	ck, cok := FailedStep(exit)
	if !cok {
		return 0, nil, false
	}
	if k, rc, ok := ParseFailedMarker(stderrTail); ok && min(k, maxStepExit-stepExitBase) == ck {
		return k, &rc, true
	}
	return ck, nil, true
}

// FailedStep maps a joined script's exit code back to the step that failed (capped: every step
// from maxStepExit-stepExitBase on maps to that step).
func FailedStep(exit int32) (int, bool) {
	if exit < stepExitBase || exit > maxStepExit {
		return 0, false
	}
	return int(exit - stepExitBase), true
}
