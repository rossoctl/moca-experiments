package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/probe is analysis/make_probe.py's output for testdata/corpus-small.jsonl (5 calls per
// class): every probe corpus must pass validatePlans unchanged.
func TestProbeCorporaValidate(t *testing.T) {
	lib, err := LoadLibrary("testdata/library.json")
	if err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob("testdata/probe/*/corpus.jsonl")
	b, err := os.ReadFile("testdata/probe/classes.txt")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Fields(string(b))
	if len(files) != len(want) || len(want) < 5 {
		t.Fatalf("%d probe corpora for classes %v", len(files), want)
	}
	for _, f := range files {
		ss, err := LoadCorpus(f)
		if err != nil || len(ss) != 1 || ss[0].User != "probe" || len(ss[0].Calls) != 5 {
			t.Fatalf("%s: %v %+v", f, err, ss)
		}
		if err := validatePlans(ss, lib, 1, Scan{}); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
	}
}
