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

// Plan expands one call into the commands to send, deterministically for (seed, sessionID, c.I).
// Classes without a library entry use the interpreter stand-in; host_infra is sleep plus
// interpreter invocations.
func (l *Library) Plan(c Call, seed int64, sessionID string) ([]Planned, error) {
	rng := rand.New(rand.NewSource(callSeed(seed, sessionID, c.I)))
	interp := l.Classes[l.Standin.InterpreterClass]
	var steps []step
	switch {
	case c.Class == "host_infra":
		sleepMs := int64(math.Round(float64(c.WorkMs)*l.Standin.InfraSleepFrac/100)) * 100
		if sleepMs > 0 {
			steps = append(steps, step{Planned{Cmd: fmt.Sprintf("sleep %.1f", float64(sleepMs)/1000)}, sleepMs})
		}
		if rem := c.WorkMs - sleepMs; rem >= 50 || len(steps) == 0 {
			steps = append(steps, fill(interp, rem, rng)...)
		}
	case len(l.Classes[c.Class]) > 0:
		steps = fill(l.Classes[c.Class], c.WorkMs, rng)
	case c.Class == "opaque" || c.Class == "build":
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
	if c.Chain && len(out) > 0 {
		if tail := c.DurMs - sum; tail > 0 {
			out[len(out)-1].SleepAfterMs = tail
		}
	}
	return out, nil
}

// A joined script exits stepExitBase+k when its step k (from 0) exits other than the library
// expects, capped at maxStepExit so the code stays below the shell's 126+ range (not executable,
// not found, killed by a signal). Steps from 35 on all report maxStepExit.
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
func JoinPlan(steps []Planned, tailMs int64) (string, error) {
	if len(steps) == 0 {
		return "", errors.New("join: no steps")
	}
	var b strings.Builder
	for k, p := range steps {
		code := stepExitBase + k
		if code > maxStepExit {
			code = maxStepExit
		}
		fmt.Fprintf(&b, "(\n%s\n); __rc=$?; [ \"$__rc\" -eq %d ] || exit %d\n", p.Cmd, p.Exit, code)
	}
	if tailMs > 0 {
		fmt.Fprintf(&b, "sleep %.1f\n", float64(tailMs)/1000)
	}
	b.WriteString("exit 0\n")
	return b.String(), nil
}

// FailedStep maps a joined script's exit code back to the step that failed.
func FailedStep(exit int32) (int, bool) {
	if exit < stepExitBase || exit > maxStepExit {
		return 0, false
	}
	return int(exit - stepExitBase), true
}
