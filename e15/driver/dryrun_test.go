package main

import (
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
// that compressed (a run of >= 2 identical steps), the p99 and max raw joined bytes and encoded
// guest frame bytes (guestFrameBytes, what validatePlans checks), and the count over
// maxJoinedBytes, listing any over-limit call (class, steps, distinct commands). It fails if any
// call is over.
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
			var raw, enc []int
			compressed, over := 0, 0
			top, topLen := "", 0
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
					n := guestFrameBytes(script)
					raw = append(raw, len(script))
					enc = append(enc, n)
					for k := 1; k < len(p); k++ {
						if p[k].Cmd == p[k-1].Cmd && p[k].Exit == p[k-1].Exit {
							compressed++
							break
						}
					}
					distinct := func() int {
						d := map[string]bool{}
						for _, x := range p {
							d[x.Cmd] = true
						}
						return len(d)
					}
					if n > topLen {
						topLen = n
						top = fmt.Sprintf("%s call %d class %s, %d steps, %d distinct commands", s.ID, c.I, c.Class, len(p), distinct())
					}
					if n > maxJoinedBytes {
						over++
						t.Errorf("OVER %s seed %d: %s call %d class %s, %d steps, %d distinct commands, raw %d, encoded %d",
							path, seed, s.ID, c.I, c.Class, len(p), distinct(), len(script), n)
					}
				}
			}
			sort.Ints(raw)
			sort.Ints(enc)
			t.Logf("%s seed %d: calls %d, compressed %d (%.2f%%); raw p99 %d max %d; encoded frame p99 %d max %d; over %d encoded: %d; largest: %s",
				path, seed, len(enc), compressed, 100*float64(compressed)/float64(len(enc)),
				pctl(raw, 99), raw[len(raw)-1], pctl(enc, 99), enc[len(enc)-1], maxJoinedBytes, over, top)
		}
	}
}

// pctl is the nearest-rank percentile of sorted v (holds.py's definition).
func pctl(v []int, q float64) int {
	k := int(float64(len(v))*q/100 + 0.999999999)
	if k < 1 {
		k = 1
	}
	return v[k-1]
}
