package main

// ownwalk subcommand (E17b, spec §7.4): the cost of the lease's ownership walk (lease spec §3.3,
// ruling R7) against workspace size. Opt-in: nothing in the replay path calls it (E17B-R4).
//
//	e15-driver ownwalk --files {10000|100000|500000} --build-script build_tree.sh --token-key K
//	  --token-iss ISS --idle-timeout-s S --run-id RUN --out DIR [--repeats 5] [--target ...]
//
// Each repeat takes a fresh workspace key (RUN-<rep>, pre-created by the rig) and sends, in order:
//  1. the per-exec write: build_tree.sh as one per-exec Exec (a sandbox token with mode per-exec,
//     epoch 0), which writes the N-file tree as root. A new workspace runs per-exec until
//     set_mode (worker lease_state.go), and an unknown state at set_mode means root_wrote.
//  2. LeaseControl set_mode lease, epoch 1.
//  3. A: the first lease Exec (--probe-cmd, default "true"): a fresh VM, and the walk runs.
//  4. LeaseControl reset: the lease ends; A's start cleared root_wrote, so the state is clean.
//  5. B: a cold lease Exec: a fresh VM again, no walk.
//
// The walk is A - B: the cold start and the Exec itself cancel. The medians of A, B and A - B
// over the repeats go to DIR/ownwalk.json, with every step's time and lease events. A repeat
// is valid when every step succeeded, A carried a lease start and B the end(reset) notice
// (proof that B followed the reset in a new lease). A failed step stops the probe. Exit 0 when
// every repeat is valid, 1 otherwise (ownwalk.json is still written), 2 on bad usage.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"google.golang.org/grpc/metadata"

	pb "github.com/rossoctl/moca/gen/go/sandbox/v1"
)

const (
	ownwalkPerExecMode = "per-exec" // the build token's mode claim (epoch 0, idle 0)
	ownwalkTokenSlack  = 300 * time.Second
)

// OwnwalkConfig is one probe at one workspace size.
type OwnwalkConfig struct {
	Files, Repeats int
	SandboxID      string // the worker's SANDBOX_ID: every ExecRequest.sandbox_id and the tokens' wrk
	RunID          string // the workspace keys are RunID-<rep>
	Key            TokenKey
	Iss            string
	IdleTimeoutS   int
	BuildScript    string // build_tree.sh's text, run by sh -c
	TreeDir        string // where build_tree.sh writes the tree, in the guest
	ProbeCmd       string // the command of A and B
	BuildTimeoutS  uint32
	ExecTimeoutS   uint32           // A and B; A includes the walk (the worker's normalise bound is 10 min)
	Now            func() time.Time // nil = time.Now
}

// OwnwalkStep is one call of a repeat.
type OwnwalkStep struct {
	Ms     float64             `json:"ms"`
	Exit   *int32              `json:"exit,omitempty"`
	Events []leaseEvent        `json:"events,omitempty"`
	Stdout string              `json:"stdout,omitempty"`
	Status *ownwalkLeaseStatus `json:"status,omitempty"` // set_mode's and reset's answer: the status after the op
	Error  string              `json:"error,omitempty"`
}

// ownwalkLeaseStatus is a LeaseControl answer as ownwalk.json records it.
type ownwalkLeaseStatus struct {
	Mode       string      `json:"mode"`
	EpochKnown bool        `json:"epoch_known"`
	State      string      `json:"state"`
	Pending    *leaseEvent `json:"pending,omitempty"`
}

func statusOf(st *pb.LeaseStatus) *ownwalkLeaseStatus {
	if st == nil {
		return nil
	}
	out := &ownwalkLeaseStatus{Mode: modeName(st.GetMode()), EpochKnown: st.GetEpochKnown(), State: st.GetState()}
	if p := st.GetPending(); p != nil {
		e := eventOf(p)
		out.Pending = &e
	}
	return out
}

// OwnwalkRun is one repeat on its own workspace key.
type OwnwalkRun struct {
	Rep            int         `json:"rep"`
	Key            string      `json:"key"`
	Build          OwnwalkStep `json:"build"`
	SetMode        OwnwalkStep `json:"set_mode"`
	A              OwnwalkStep `json:"a"`
	Reset          OwnwalkStep `json:"reset"`
	B              OwnwalkStep `json:"b"`
	AMs            *float64    `json:"a_ms"`
	BMs            *float64    `json:"b_ms"`
	WalkMs         *float64    `json:"walk_ms"` // A - B
	Valid          bool        `json:"valid"`
	InvalidReasons []string    `json:"invalid_reasons"`
}

// OwnwalkReport is ownwalk.json. The medians are null unless every repeat ran and is valid.
type OwnwalkReport struct {
	Files             int          `json:"files"`
	Repeats           int          `json:"repeats"`
	RunID             string       `json:"run_id"`
	SandboxID         string       `json:"sandbox_id"`
	IdleTimeoutS      int          `json:"idle_timeout_s"`
	ProbeCmd          string       `json:"probe_cmd"`
	TreeDir           string       `json:"tree_dir"`
	BuildScriptSha256 string       `json:"build_script_sha256"`
	Runs              []OwnwalkRun `json:"runs"`
	MedianAMs         *float64     `json:"median_a_ms"`
	MedianBMs         *float64     `json:"median_b_ms"`
	MedianWalkMs      *float64     `json:"median_walk_ms"` // the median of the per-repeat A - B
	Valid             bool         `json:"valid"`
	InvalidReasons    []string     `json:"invalid_reasons"`
}

// ownwalkKey is repeat rep's workspace key; the rig pre-creates the same names.
func ownwalkKey(runID string, rep int) string { return fmt.Sprintf("%s-%d", runID, rep) }

// shQuote quotes s for a POSIX shell.
func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// ownwalkBuildCmd runs build_tree.sh's text in the guest: sh -c SCRIPT build_tree.sh DIR N.
func ownwalkBuildCmd(script, dir string, files int) string {
	return fmt.Sprintf("sh -c %s build_tree.sh %s %d", shQuote(script), shQuote(dir), files)
}

// median of a non-empty slice (the mean of the two middle values for an even count).
func median(v []float64) float64 {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

func f64(v float64) *float64 { return &v }

// RunOwnwalk runs the probe. The report is returned whatever happens; the error is a failed step
// (the probe stops there) and is nil when every step succeeded, valid or not.
func RunOwnwalk(ctx context.Context, client pb.SandboxExecClient, cfg OwnwalkConfig) (*OwnwalkReport, error) {
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	sum := sha256.Sum256([]byte(cfg.BuildScript))
	rep := &OwnwalkReport{
		Files: cfg.Files, Repeats: cfg.Repeats, RunID: cfg.RunID, SandboxID: cfg.SandboxID, IdleTimeoutS: cfg.IdleTimeoutS,
		ProbeCmd: cfg.ProbeCmd, TreeDir: cfg.TreeDir, BuildScriptSha256: hex.EncodeToString(sum[:]),
		Runs: []OwnwalkRun{}, InvalidReasons: []string{},
	}
	// The lease tokens outlive A by construction: the Refresher hands out a token with at least
	// 30% of its TTL left, and 30% of 4 x the Exec timeout is more than one Exec may take (the
	// relay cuts an Exec at its token's exp).
	lcfg := &LeaseConfig{Key: cfg.Key, Iss: cfg.Iss, Wrk: cfg.SandboxID, IdleTimeoutS: cfg.IdleTimeoutS,
		TokenTTL: 4 * time.Duration(cfg.ExecTimeoutS) * time.Second}
	reqID := uint64(0)
	next := func() uint64 { reqID++; return reqID }
	buildCmd := ownwalkBuildCmd(cfg.BuildScript, cfg.TreeDir, cfg.Files)

	var stepErr error
	for i := 0; i < cfg.Repeats && stepErr == nil; i++ {
		key := ownwalkKey(cfg.RunID, i)
		run := OwnwalkRun{Rep: i, Key: key, InvalidReasons: []string{}}
		fail := func(st *OwnwalkStep, what string, err error) {
			st.Error = err.Error()
			run.InvalidReasons = append(run.InvalidReasons, what+": "+err.Error())
			stepErr = fmt.Errorf("repeat %d (%s) %s: %w", i, key, what, err)
		}
		runExec := func(st *OwnwalkStep, what string, ectx context.Context, cmd string, timeoutS uint32, keep bool) bool {
			t0 := now()
			res := execOne(ectx, client, cfg.SandboxID, next(), cmd, timeoutS, key, keep)
			st.Ms = ms(now().Sub(t0))
			st.Exit, st.Events, st.Stdout = res.exit, res.events, string(cutRunes(res.stdout))
			switch {
			case res.cause != "":
				fail(st, what, fmt.Errorf("%s: %s", res.cause, res.msg))
			case *res.exit != 0:
				fail(st, what, fmt.Errorf("exit %d (stderr %q)", *res.exit, string(res.stderr)))
			default:
				return true
			}
			return false
		}

		// 1. the per-exec write, as root (mode per-exec, epoch 0: before any set_mode).
		btok, err := cfg.Key.MintSandbox(SandboxClaims{
			Iss: cfg.Iss, Sub: leaseSub, Tenant: leaseTenant, Sbx: key, Wrk: cfg.SandboxID,
			Mode: ownwalkPerExecMode, ModeEpoch: 0, IdleTimeoutS: 0,
			TTL: time.Duration(cfg.BuildTimeoutS)*time.Second + ownwalkTokenSlack,
		})
		if err != nil {
			fail(&run.Build, "build token", err)
			rep.Runs = append(rep.Runs, run)
			break
		}
		bctx := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+btok)
		if !runExec(&run.Build, "build", bctx, buildCmd, cfg.BuildTimeoutS, true) {
			rep.Runs = append(rep.Runs, run)
			break
		}
		if want := fmt.Sprintf("files=%d", cfg.Files); !strings.Contains(" "+run.Build.Stdout+" ", " "+want+" ") {
			fail(&run.Build, "build", fmt.Errorf("its output %q does not report %s", run.Build.Stdout, want))
			rep.Runs = append(rep.Runs, run)
			break
		}

		// 2. per-exec -> lease, epoch 1.
		ls := newLeaseSession(lcfg, key)
		t0 := now()
		err = ls.setMode(ctx, client)
		run.SetMode.Ms = ms(now().Sub(t0))
		if err != nil {
			fail(&run.SetMode, "set_mode", err)
			rep.Runs = append(rep.Runs, run)
			break
		}

		// 3. A: the first lease Exec; the walk runs.
		actx, err := ls.bearer(ctx)
		if err != nil {
			fail(&run.A, "A token", err)
			rep.Runs = append(rep.Runs, run)
			break
		}
		if !runExec(&run.A, "A", actx, cfg.ProbeCmd, cfg.ExecTimeoutS, false) {
			rep.Runs = append(rep.Runs, run)
			break
		}

		// 4. reset: the lease ends, the state is known and clean.
		t0 = now()
		rst, err := ls.reset(ctx, client)
		run.Reset.Ms, run.Reset.Status = ms(now().Sub(t0)), statusOf(rst)
		if err != nil {
			fail(&run.Reset, "reset", err)
			rep.Runs = append(rep.Runs, run)
			break
		}

		// 5. B: a cold lease Exec, no walk.
		bctx, err = ls.bearer(ctx)
		if err != nil {
			fail(&run.B, "B token", err)
			rep.Runs = append(rep.Runs, run)
			break
		}
		if !runExec(&run.B, "B", bctx, cfg.ProbeCmd, cfg.ExecTimeoutS, false) {
			rep.Runs = append(rep.Runs, run)
			break
		}

		run.AMs, run.BMs, run.WalkMs = f64(run.A.Ms), f64(run.B.Ms), f64(run.A.Ms-run.B.Ms)
		if !hasStart(run.A.Events) {
			run.InvalidReasons = append(run.InvalidReasons, "A carried no lease start event: it did not start a lease")
		}
		if !hasResetEnd(run.B.Events) {
			run.InvalidReasons = append(run.InvalidReasons, "B carried no end(reset) event: it is not known to follow the reset in a new lease")
		}
		run.Valid = len(run.InvalidReasons) == 0
		rep.Runs = append(rep.Runs, run)
	}

	var as, bs, ws []float64
	for _, r := range rep.Runs {
		if !r.Valid {
			rep.InvalidReasons = append(rep.InvalidReasons, fmt.Sprintf("repeat %d: %s", r.Rep, strings.Join(r.InvalidReasons, "; ")))
			continue
		}
		as, bs, ws = append(as, *r.AMs), append(bs, *r.BMs), append(ws, *r.WalkMs)
	}
	if len(rep.Runs) < cfg.Repeats {
		rep.InvalidReasons = append(rep.InvalidReasons, fmt.Sprintf("%d of %d repeats ran", len(rep.Runs), cfg.Repeats))
	}
	rep.Valid = len(rep.InvalidReasons) == 0
	if rep.Valid && len(ws) > 0 {
		rep.MedianAMs, rep.MedianBMs, rep.MedianWalkMs = f64(median(as)), f64(median(bs)), f64(median(ws))
	}
	return rep, stepErr
}

func hasResetEnd(evs []leaseEvent) bool {
	for _, e := range evs {
		if e.State == "end" && e.Reason == "reset" {
			return true
		}
	}
	return false
}

// writeOwnwalk writes the report, indented, atomically (a temp file renamed over path).
func writeOwnwalk(path string, rep *OwnwalkReport) error {
	b, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func ownwalkMain(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("e15-driver ownwalk", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		files     = fs.Int("files", 0, "workspace size in files: 10000, 100000 or 500000")
		repeats   = fs.Int("repeats", 5, "repeats, each on a fresh workspace key; the median is reported")
		target    = fs.String("target", "127.0.0.1:9644", "SandboxExec host:port")
		sandboxID = fs.String("sandbox-id", "e15", "the worker's SANDBOX_ID: sandbox_id on every ExecRequest and the tokens' wrk")
		tokenKey  = fs.String("token-key", "", "Ed25519 private key (PKCS#8 PEM) the relay's SH_SANDBOX_TOKEN_PUBLIC_KEYS lists")
		tokenIss  = fs.String("token-iss", "", "the token issuer, equal to the relay's SH_SANDBOX_TOKEN_ISSUER (required)")
		idleTmoS  = fs.Int("idle-timeout-s", 0, "the lease idle timeout, seconds (token claim idle_timeout_s); >= 1")
		runID     = fs.String("run-id", "", "the workspace keys are RUN-ID-<rep>, pre-created by the rig")
		out       = fs.String("out", "", "output directory: ownwalk.json")
		script    = fs.String("build-script", "", "build_tree.sh: run as the per-exec Exec that writes the tree as root")
		treeDir   = fs.String("tree-dir", "/workspace/ownwalk-tree", "where the tree is built, in the guest")
		probeCmd  = fs.String("probe-cmd", "true", "the command of A and B")
		buildTmoS = fs.Int("build-timeout-s", 3600, "the per-exec build's timeout_s")
		execTmoS  = fs.Int("exec-timeout-s", 900, "A's and B's timeout_s (A includes the walk)")
	)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fail := func(code int, f string, a ...any) int {
		fmt.Fprintf(stderr, "e15-driver ownwalk: "+f+"\n", a...)
		return code
	}
	switch {
	case fs.NArg() != 0:
		return fail(2, "unexpected arguments %v", fs.Args())
	case *files != 10000 && *files != 100000 && *files != 500000:
		return fail(2, "--files must be 10000, 100000 or 500000 (spec §7.4), got %d", *files)
	case *repeats < 1:
		return fail(2, "--repeats >= 1 is required")
	case *tokenIss == "":
		return fail(2, "--token-iss is required (it must equal the relay's SH_SANDBOX_TOKEN_ISSUER)")
	case *tokenKey == "":
		return fail(2, "--token-key is required")
	case *idleTmoS < 1:
		return fail(2, "--idle-timeout-s >= 1 is required")
	case *runID == "" || *out == "":
		return fail(2, "--run-id and --out are required")
	case *script == "":
		return fail(2, "--build-script is required")
	case *buildTmoS < 1 || *execTmoS < 1:
		return fail(2, "--build-timeout-s and --exec-timeout-s must be >= 1")
	}
	body, err := os.ReadFile(*script)
	if err != nil {
		return fail(2, "reading the build script: %v", err)
	}
	k, err := LoadTokenKey(*tokenKey)
	if err != nil {
		return fail(2, "loading --token-key: %v", err)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return fail(1, "%v", err)
	}
	ctx := context.Background()
	dialCtx, cancel := context.WithTimeout(ctx, dialTimeout)
	cc, err := dialReady(dialCtx, *target)
	cancel()
	if err != nil {
		return fail(1, "%v", err)
	}
	defer func() { _ = cc.Close() }()
	rep, runErr := RunOwnwalk(ctx, pb.NewSandboxExecClient(cc), OwnwalkConfig{
		Files: *files, Repeats: *repeats, SandboxID: *sandboxID, RunID: *runID, Key: k, Iss: *tokenIss,
		IdleTimeoutS: *idleTmoS, BuildScript: string(body), TreeDir: *treeDir, ProbeCmd: *probeCmd,
		BuildTimeoutS: uint32(*buildTmoS), ExecTimeoutS: uint32(*execTmoS),
	})
	path := filepath.Join(*out, "ownwalk.json")
	if err := writeOwnwalk(path, rep); err != nil {
		return fail(1, "writing %s: %v", path, err)
	}
	for _, r := range rep.Runs {
		if r.WalkMs != nil {
			fmt.Fprintf(stderr, "ownwalk files=%d repeat %d key %s: A %.1f ms, B %.1f ms, A-B %.1f ms, valid %v\n",
				*files, r.Rep, r.Key, *r.AMs, *r.BMs, *r.WalkMs, r.Valid)
		}
	}
	switch {
	case runErr != nil:
		return fail(1, "stopped: %v (%s written)", runErr, path)
	case !rep.Valid:
		return fail(1, "invalid: %s (%s written)", strings.Join(rep.InvalidReasons, "; "), path)
	}
	fmt.Fprintf(stderr, "ownwalk files=%d: median A %.1f ms, median B %.1f ms, median walk (A-B) %.1f ms over %d repeats (%s)\n",
		*files, *rep.MedianAMs, *rep.MedianBMs, *rep.MedianWalkMs, len(rep.Runs), path)
	return 0
}
