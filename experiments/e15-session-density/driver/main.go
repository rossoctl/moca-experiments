package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

func main() {
	os.Exit(realMain(os.Args[1:], os.Getenv, os.Stderr))
}

// dialTimeout bounds connection setup only; the run itself is bounded by --warmup-s + --window-s.
const dialTimeout = 30 * time.Second

func realMain(args []string, getenv func(string) string, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "mint-key" {
		return mintKeyMain(args[1:], stderr)
	}
	if len(args) > 0 && args[0] == "ownwalk" {
		return ownwalkMain(args[1:], stderr)
	}
	fs := flag.NewFlagSet("e15-driver", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		corpus    = fs.String("corpus", "", "corpus.jsonl")
		library   = fs.String("library", "", "library.json")
		seed      = fs.Int64("seed", 1, "replay seed (SPEC §5.8)")
		n         = fs.Int("n", 0, "session population N")
		userCap   = fs.Float64("user-cap", 0.15, "max fraction of the live population one user may hold (SPEC §5.7)")
		warmupS   = fs.Int("warmup-s", 600, "unmeasured warm-up, seconds")
		windowS   = fs.Int("window-s", 900, "measured window, seconds")
		spreadS   = fs.Int("spread-s", 60, "first sessions start spread over this many seconds")
		maxSess   = fs.Int("max-sessions", 0, "start at most this many sessions in total, then end the run early (0 = unlimited; class probe)")
		startZero = fs.Bool("start-at-zero", false, "every session starts at its first call (class probe)")
		endSess   = fs.Bool("end-session-exec", false, "send '"+EndSessionCommand+"' on a session's workspace_key when it ends (resident arm)")
		endDefer  = fs.Bool("end-session-defer", false, "E16 supplementary: end-session Execs of sessions the run's end stopped are sent after the grace deadline, ordered by slot, paced (--end-session-rate); natural ends unchanged; default off")
		endRate   = fs.Int("end-session-rate", 50, "with --end-session-defer: deferred end-session Exec starts per second")
		graceS    = fs.Int("grace-s", 300, "after the run's end, Execs still in flight are cancelled after this many seconds")
		target    = fs.String("target", "127.0.0.1:9644", "SandboxExec host:port")
		sandboxID = fs.String("sandbox-id", "e15", "sandbox_id on every ExecRequest")
		runID     = fs.String("run-id", "", "run identifier, part of every workspace_key")
		out       = fs.String("out", "", "output directory")
		scanCmd   = fs.String("scan-cmd", "", "mem512: a command run ONCE at the start of every call of a --scan-classes class (exit 89 if it fails); default off")
		leaseMode leaseModeFlag
		tokenKey  = fs.String("token-key", "", "with --lease-mode: Ed25519 private key (PKCS#8 PEM) the relay's SH_SANDBOX_TOKEN_PUBLIC_KEYS lists")
		idleTmoS  = fs.Int("idle-timeout-s", 0, "with --lease-mode: the lease idle timeout, seconds (token claim idle_timeout_s); required, >= 1")
		tokenWrk  = fs.String("token-wrk", "e15", "with --lease-mode: the worker's SANDBOX_ID (token claim wrk); must equal --sandbox-id")
		tokenIss  = fs.String("token-iss", "", "with --lease-mode: the token issuer, equal to the relay's SH_SANDBOX_TOKEN_ISSUER (required, no default)")
		scanCls   = fs.String("scan-classes", "", "mem512: comma-separated classes whose calls carry --scan-cmd")
		recStdout = fs.String("record-stdout", "", "E17b: comma-separated classes whose calls record the Exec's stdout in calls.jsonl (first 1024 bytes; default off)")
		l2Restart = fs.Bool("l2-restart", false, "E17d, with --lease-mode=lease+processes only: a level-2 client call that exits 3 (no server answered its probe) starts l2srv with process_start and re-runs the client with --wait 60 (spec §14.2)")
	)
	fs.Var(&leaseMode, "lease-mode", "E17b: send LeaseControl set_mode before each session's first Exec, authenticate with per-session sandbox tokens, record LeaseEvents, sweep lease status at the end (default off: the E15 driver). Bare, the mode claim is lease; E17d: --lease-mode=lease+processes")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fail := func(code int, f string, a ...any) int {
		fmt.Fprintf(stderr, "e15-driver: "+f+"\n", a...)
		return code
	}
	if fs.NArg() > 0 {
		return fail(2, "unexpected argument %q (a --lease-mode value is joined with '=': --lease-mode=lease+processes)", fs.Arg(0))
	}
	if *l2Restart && leaseMode.mode != leaseModeL2 {
		return fail(2, "--l2-restart needs --lease-mode=lease+processes (the restart starts a tracked process, level 2 only); got --lease-mode=%q", leaseMode.mode)
	}
	token := getenv("MOCA_RELAY_EXEC_TOKEN")
	var lease *LeaseConfig
	if leaseMode.mode != "" {
		// Sandbox tokens replace the worker credential: the relay's sandbox path refuses it.
		switch {
		case *tokenIss == "":
			return fail(2, "--token-iss is required with --lease-mode (it must equal the relay's SH_SANDBOX_TOKEN_ISSUER)")
		case *tokenKey == "":
			return fail(2, "--token-key is required with --lease-mode")
		case *idleTmoS < 1:
			return fail(2, "--idle-timeout-s >= 1 is required with --lease-mode")
		case *tokenWrk != *sandboxID:
			return fail(2, "--token-wrk %q must equal --sandbox-id %q: the relay requires ExecRequest.sandbox_id == the token's wrk", *tokenWrk, *sandboxID)
		}
		k, kerr := LoadTokenKey(*tokenKey)
		if kerr != nil {
			return fail(2, "loading --token-key: %v", kerr)
		}
		lease = &LeaseConfig{Key: k, Iss: *tokenIss, Wrk: *tokenWrk, IdleTimeoutS: *idleTmoS, Mode: leaseMode.mode, L2Restart: *l2Restart}
	}
	if token == "" && lease == nil {
		return fail(2, "MOCA_RELAY_EXEC_TOKEN is not set: the relay refuses SandboxExec without the worker credential")
	}
	if *corpus == "" || *library == "" || *runID == "" || *out == "" || *n < 1 {
		return fail(2, "--corpus, --library, --run-id, --out and --n >= 1 are required")
	}
	scan, err := ParseScan(*scanCmd, *scanCls)
	if err != nil {
		return fail(2, "%v", err)
	}
	recordStdout, err := ParseRecordStdout(*recStdout)
	if err != nil {
		return fail(2, "%v", err)
	}
	ss, err := LoadCorpus(*corpus)
	if err != nil {
		return fail(1, "loading corpus: %v", err)
	}
	lib, err := LoadLibrary(*library)
	if err != nil {
		return fail(1, "loading library: %v", err)
	}
	for _, w := range recordStdoutWarnings(ss, recordStdout) {
		fmt.Fprintln(stderr, w)
	}
	if err := scan.Check(lib); err != nil {
		return fail(2, "%v", err)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return fail(1, "%v", err)
	}
	var files []*os.File
	open := func(name string) io.Writer {
		f, ferr := os.OpenFile(filepath.Join(*out, name), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if ferr != nil {
			err = errors.Join(err, ferr)
			return io.Discard
		}
		files = append(files, f)
		return f
	}
	rec := NewRecorder(open("calls.jsonl"), open("sessions.jsonl"), open("driver-cpu.jsonl"))
	if lease != nil {
		rec.SetLeaseTail(open("lease-tail.jsonl"))
	}
	if err != nil {
		return fail(1, "opening outputs: %v", err)
	}
	closeAll := func() error {
		errs := []error{rec.Flush()}
		for _, f := range files {
			errs = append(errs, f.Close())
		}
		return errors.Join(errs...)
	}

	// SIGINT/SIGTERM cancel the run; whatever was recorded is still flushed.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dialCtx, cancelDial := context.WithTimeout(ctx, dialTimeout)
	cc, err := dialReady(dialCtx, *target)
	cancelDial()
	if err != nil {
		_ = closeAll()
		return fail(1, "%v", err)
	}
	defer func() { _ = cc.Close() }()

	r, err := NewReplayer(Config{
		N: *n, Seed: *seed, UserCap: *userCap,
		Warmup: time.Duration(*warmupS) * time.Second, Window: time.Duration(*windowS) * time.Second,
		Spread: time.Duration(*spreadS) * time.Second, Grace: time.Duration(*graceS) * time.Second, EndSessionExec: *endSess, EndSessionDefer: *endDefer, EndSessionRate: *endRate, StartAtZero: *startZero, MaxSessions: *maxSess, Scan: scan, SandboxID: *sandboxID, RunID: *runID, Token: token, Lease: lease, RecordStdout: recordStdout,
	}, ss, lib, pb.NewSandboxExecClient(cc), rec)
	if err != nil {
		_ = closeAll()
		return fail(1, "%v", err)
	}
	runErr := r.Run(ctx)
	if err := closeAll(); err != nil {
		return fail(1, "writing outputs: %v", err)
	}
	switch {
	case errors.Is(runErr, ErrCapUnsatisfiable):
		return fail(1, "aborting run: the corpus cannot fill N=%d under the per-user cap %.2f: %v", *n, *userCap, runErr)
	case runErr != nil:
		return fail(1, "run aborted: %v", runErr)
	}
	if err := leaseRunVerdict(r); err != nil {
		return fail(1, "%v", err)
	}
	return 0
}
