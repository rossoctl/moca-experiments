package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// TestDryRunJoinedSizes is the frame-limit dry run over real corpora, skipped unless
// E15_DRYRUN_CORPORA is set:
//
//	E15_DRYRUN_CORPORA=a/corpus.jsonl,b/corpus.jsonl E15_DRYRUN_LIBRARY=../commands/library.json \
//	  [E15_DRYRUN_SEEDS=1,2,3] go test -run TestDryRunJoinedSizes -v .
//
// For each corpus and seed it plans and joins every call validatePlans would, and logs the calls
// that compressed (a run of >= 2 identical steps), the p99 and max joined bytes before and after
// compression, and the count over maxJoinedBytes, listing any over-limit call (class, steps,
// distinct commands). It fails if any call is over.
func TestDryRunJoinedSizes(t *testing.T) {
	corpora := os.Getenv("E15_DRYRUN_CORPORA")
	if corpora == "" {
		t.Skip("E15_DRYRUN_CORPORA not set")
	}
	l, err := LoadLibrary(os.Getenv("E15_DRYRUN_LIBRARY"))
	if err != nil {
		t.Fatal(err)
	}
	seeds := []int64{1}
	if v := os.Getenv("E15_DRYRUN_SEEDS"); v != "" {
		seeds = nil
		for _, f := range strings.Split(v, ",") {
			n, err := strconv.ParseInt(f, 10, 64)
			if err != nil {
				t.Fatal(err)
			}
			seeds = append(seeds, n)
		}
	}
	for _, path := range strings.Split(corpora, ",") {
		ss, err := LoadCorpus(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, seed := range seeds {
			var after, before []int
			compressed, over, near, encOver, encMax := 0, 0, 0, 0, 0
			var top string
			topLen := 0
			for _, s := range ss {
				if len(s.Calls) < minCalls {
					continue
				}
				for _, c := range s.Calls {
					p, err := l.Plan(c, seed, s.ID)
					if err != nil {
						t.Fatal(err)
					}
					script, _ := JoinPlan(p, p[len(p)-1].SleepAfterMs)
					after = append(after, len(script))
					before = append(before, uncompressedLen(p))
					for k := 1; k < len(p); k++ {
						if p[k].Cmd == p[k-1].Cmd && p[k].Exit == p[k-1].Exit {
							compressed++
							break
						}
					}
					// the guest frame carries the script inside a JSON Request (json.Marshal
					// escapes <, >, & and newlines): what MaxFrame actually bounds
					if len(script) > 16<<10 {
						eb, _ := json.Marshal(struct {
							Command string `json:"command"`
						}{script})
						if len(eb) > encMax {
							encMax = len(eb)
						}
						if len(eb) > 32<<10-256 {
							encOver++
							distinct := map[string]bool{}
							for _, x := range p {
								distinct[x.Cmd] = true
							}
							t.Logf("ENCODED-OVER %s: %s call %d class %s, %d steps, %d distinct commands, raw %d, json %d",
								path, s.ID, c.I, c.Class, len(p), len(distinct), len(script), len(eb))
						}
					}
					if len(script) > 24<<10 {
						near++
					}
					if len(script) > topLen {
						distinct := map[string]bool{}
						for _, x := range p {
							distinct[x.Cmd] = true
						}
						topLen = len(script)
						top = fmt.Sprintf("%s call %d class %s, %d steps, %d distinct commands", s.ID, c.I, c.Class, len(p), len(distinct))
					}
					if len(script) > maxJoinedBytes {
						over++
						distinct := map[string]bool{}
						for _, x := range p {
							distinct[x.Cmd] = true
						}
						t.Errorf("OVER %s: %s call %d class %s, %d steps, %d distinct commands, %d bytes",
							path, s.ID, c.I, c.Class, len(p), len(distinct), len(script))
					}
				}
			}
			sort.Ints(after)
			sort.Ints(before)
			t.Logf("%s seed %d: calls %d, compressed %d (%.2f%%); joined bytes before p99 %d max %d; after p99 %d max %d; over 24 KiB %d; over %d: %d; JSON-encoded max %d, over 32 KiB-256: %d; largest: %s",
				path, seed, len(after), compressed, 100*float64(compressed)/float64(len(after)),
				pctl(before, 99), before[len(before)-1], pctl(after, 99), after[len(after)-1], near, maxJoinedBytes, over, encMax, encOver, top)
		}
	}
}

// uncompressedLen is the size the joined script had before run-length encoding (one block per step).
func uncompressedLen(p []Planned) int {
	n := len("exit 0\n")
	for k, x := range p {
		n += len(fmt.Sprintf("(\n%s\n); __rc=$?; [ \"$__rc\" -eq %d ] || { echo \"%s%d RC=$__rc\" >&2; exit %d; }\n",
			x.Cmd, x.Exit, failedMarker, k, min(stepExitBase+k, maxStepExit)))
	}
	if t := p[len(p)-1].SleepAfterMs; t > 0 {
		n += len(fmt.Sprintf("sleep %.3f\n", float64(t)/1000))
	}
	return n
}

// pctl is the nearest-rank percentile of sorted v (holds.py's definition).
func pctl(v []int, q float64) int {
	k := int(float64(len(v))*q/100 + 0.999999999)
	if k < 1 {
		k = 1
	}
	return v[k-1]
}
