package main

// E17d (PLAN-E17D Task 2, spec §14.2): the lease mode is a per-rung value. --lease-mode=MODE is the mode claim of every
// Exec token and of the set-mode token; bare --lease-mode (E17b and E17c's rungs) stays "lease". --l2-restart is
// accepted only with lease+processes.

import (
	"bytes"
	"strings"
	"testing"
)

func TestLeaseModeProcessesClaimInEveryToken(t *testing.T) {
	for _, mode := range []string{"", "lease", "lease+processes"} {
		client, lr := newLeaseRelay(t)
		lr.execEvents = startsOnFirst
		cfg := leaseCfg()
		cfg.Lease.Mode = mode
		cfg.MaxSessions = 1
		res, _, _ := leaseRun(t, cfg, []Session{sess("s", "u", 20, "q", "q", "q")}, testLib(nil, "q"), client)
		if res.err != nil {
			t.Fatal(res.err)
		}
		want := mode
		if want == "" {
			want = "lease" // the default: E17b and E17c's rungs
		}
		key := "e15-t-0-0"
		sm, ok := lr.setModeOf(key)
		if !ok {
			t.Fatal("no set_mode")
		}
		execs := lr.execsOf(key)
		if len(execs) != 3 {
			t.Fatalf("mode %q: %d execs", mode, len(execs))
		}
		claims := map[string]map[string]any{"set-mode": sm.setMode, "bearer of set_mode": sm.bearer}
		for i, e := range execs {
			claims["exec "+string(rune('0'+i))] = e.bearer
		}
		for name, c := range claims {
			if c["mode"] != want {
				t.Fatalf("mode %q: %s token's mode claim is %v, want %s", mode, name, c["mode"], want)
			}
		}
	}
}

func TestLeaseModeFlagValues(t *testing.T) {
	for in, want := range map[string]string{"true": "lease", "lease": "lease", "lease+processes": "lease+processes"} {
		var m leaseModeFlag
		if err := m.Set(in); err != nil || m.mode != want {
			t.Fatalf("Set(%q): %q %v, want %q", in, m.mode, err, want)
		}
	}
	for _, in := range []string{"false", "", "per-exec", "processes", "Lease"} {
		var m leaseModeFlag
		if err := m.Set(in); err == nil {
			t.Fatalf("Set(%q) accepted as %q", in, m.mode)
		}
	}
	var m leaseModeFlag
	if !m.IsBoolFlag() || m.String() != "" {
		t.Fatalf("bare --lease-mode must stay a boolean switch, off by default: %q", m.String())
	}
}

func TestL2RestartNeedsLeaseProcesses(t *testing.T) {
	base := []string{"--corpus", "x", "--library", "y", "--run-id", "r", "--out", t.TempDir(), "--n", "1",
		"--token-key", "k", "--token-iss", "i", "--idle-timeout-s", "300"}
	var buf bytes.Buffer
	for name, c := range map[string]struct {
		extra []string
		want  string
	}{
		"l2-restart without lease mode":   {[]string{"--l2-restart"}, "--l2-restart needs --lease-mode=lease+processes"},
		"l2-restart at level 1 (bare)":    {[]string{"--lease-mode", "--l2-restart"}, "--l2-restart needs --lease-mode=lease+processes"},
		"l2-restart at level 1 (=lease)":  {[]string{"--lease-mode=lease", "--l2-restart"}, "--l2-restart needs --lease-mode=lease+processes"},
		"an unknown mode":                 {[]string{"--lease-mode=per-exec"}, "--lease-mode"},
		"the mode as a separate argument": {[]string{"--lease-mode", "lease+processes"}, "unexpected argument"},
	} {
		buf.Reset()
		if code := realMain(append(append([]string{}, base...), c.extra...), func(string) string { return "" }, &buf); code != 2 || !strings.Contains(buf.String(), c.want) {
			t.Fatalf("%s: exit %d, want 2 with %q: %s", name, code, c.want, buf.String())
		}
	}
}
