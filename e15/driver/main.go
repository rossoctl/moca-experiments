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
		graceS    = fs.Int("grace-s", 300, "after the run's end, Execs still in flight are cancelled after this many seconds")
		target    = fs.String("target", "127.0.0.1:9644", "SandboxExec host:port")
		sandboxID = fs.String("sandbox-id", "e15", "sandbox_id on every ExecRequest")
		runID     = fs.String("run-id", "", "run identifier, part of every workspace_key")
		out       = fs.String("out", "", "output directory")
	)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fail := func(code int, f string, a ...any) int {
		fmt.Fprintf(stderr, "e15-driver: "+f+"\n", a...)
		return code
	}
	token := getenv("MOCA_RELAY_EXEC_TOKEN")
	if token == "" {
		return fail(2, "MOCA_RELAY_EXEC_TOKEN is not set: the relay refuses SandboxExec without the worker credential")
	}
	if *corpus == "" || *library == "" || *runID == "" || *out == "" || *n < 1 {
		return fail(2, "--corpus, --library, --run-id, --out and --n >= 1 are required")
	}
	ss, err := LoadCorpus(*corpus)
	if err != nil {
		return fail(1, "loading corpus: %v", err)
	}
	lib, err := LoadLibrary(*library)
	if err != nil {
		return fail(1, "loading library: %v", err)
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
		Spread: time.Duration(*spreadS) * time.Second, Grace: time.Duration(*graceS) * time.Second, EndSessionExec: *endSess, StartAtZero: *startZero, MaxSessions: *maxSess, SandboxID: *sandboxID, RunID: *runID, Token: token,
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
	return 0
}
