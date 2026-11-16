package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testTokenKey() TokenKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	return TokenKey{Priv: ed25519.NewKeyFromSeed(seed)}
}

func decodeJWS(t *testing.T, tok string) (hdr, claims map[string]any) {
	t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("want 3 segments, got %d", len(parts))
	}
	for i, dst := range []*map[string]any{&hdr, &claims} {
		raw, err := base64.RawURLEncoding.DecodeString(parts[i])
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, dst); err != nil {
			t.Fatal(err)
		}
	}
	return
}

func testSandboxClaims(now time.Time) SandboxClaims {
	return SandboxClaims{
		Iss: "e17b-issuer", Sub: "driver", Tenant: "e17b", Sbx: "sbx-1", Wrk: "worker-1",
		Mode: "lease", ModeEpoch: 1, IdleTimeoutS: 120, TTL: 10 * time.Minute, Now: now,
	}
}

func TestMintedTokenHasTheClaims(t *testing.T) {
	k := testTokenKey()
	now := time.Unix(1_800_000_000, 0)
	tok, err := k.MintSandbox(testSandboxClaims(now))
	if err != nil {
		t.Fatal(err)
	}
	h, c := decodeJWS(t, tok)
	if h["typ"] != "moca-sandbox+jwt" || h["alg"] != "EdDSA" || h["kid"] != k.Kid() {
		t.Fatalf("header %v", h)
	}
	str := map[string]string{"iss": "e17b-issuer", "aud": "moca-sandbox", "sub": "driver", "tenant": "e17b",
		"sbx": "sbx-1", "wrk": "worker-1", "wsk": "sbx-1", "mode": "lease"}
	for f, want := range str {
		if c[f] != want {
			t.Errorf("%s = %v, want %s", f, c[f], want)
		}
	}
	num := map[string]float64{"mode_epoch": 1, "idle_timeout_s": 120, "iat": 1_800_000_000, "exp": 1_800_000_600}
	for f, want := range num {
		if c[f] != want {
			t.Errorf("%s = %v, want %v", f, c[f], want)
		}
	}
	if s, _ := c["scope"].([]any); len(s) != 1 || s[0] != "exec" {
		t.Errorf("scope = %v", c["scope"])
	}
	if j, _ := c["jti"].(string); len(j) != 36 || strings.Count(j, "-") != 4 {
		t.Errorf("jti = %v", c["jti"])
	}
	tok2, _ := k.MintSandbox(testSandboxClaims(now))
	if _, c2 := decodeJWS(t, tok2); c2["jti"] == c["jti"] {
		t.Error("jti is not fresh")
	}
	sig := strings.Split(tok, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(sig[2])
	if !ed25519.Verify(k.Priv.Public().(ed25519.PublicKey), []byte(sig[0]+"."+sig[1]), raw) {
		t.Error("signature does not verify")
	}
}

func TestMintedSetModeTokenHasTheClaims(t *testing.T) {
	k := testTokenKey()
	now := time.Unix(1_800_000_000, 0)
	tok, err := k.MintSetMode(SetModeClaims{Iss: "e17b-issuer", Sub: "driver", Sbx: "sbx-1", Wrk: "worker-1",
		Mode: "lease", ModeEpoch: 1, IdleTimeoutS: 120, TTL: 300 * time.Second, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	h, c := decodeJWS(t, tok)
	if h["typ"] != "moca-sandbox-mode+jwt" || h["kid"] != k.Kid() {
		t.Fatalf("header %v", h)
	}
	if c["wsk"] != "sbx-1" || c["aud"] != "moca-sandbox" || c["exp"] != float64(1_800_000_300) {
		t.Errorf("claims %v", c)
	}
	for _, f := range []string{"tenant", "scope"} {
		if _, ok := c[f]; ok {
			t.Errorf("set-mode token carries %s", f)
		}
	}
	if _, err := k.MintSetMode(SetModeClaims{Iss: "i", Sub: "s", Sbx: "b", Wrk: "w", Mode: "lease", TTL: 301 * time.Second}); err == nil {
		t.Error("TTL over 300 s accepted")
	}
}

func TestKidIsTheSPKIHash(t *testing.T) {
	k := testTokenKey()
	der, err := x509.MarshalPKIXPublicKey(k.Priv.Public())
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(der)
	if want := hex.EncodeToString(sum[:8]); k.Kid() != want || len(k.Kid()) != 16 {
		t.Fatalf("kid %q want %q", k.Kid(), want)
	}
	if want := k.Kid() + ":" + base64.StdEncoding.EncodeToString(der); k.PublicKeyset() != want {
		t.Fatalf("keyset %q want %q", k.PublicKeyset(), want)
	}
}

func TestRefresherMintsBeforeExp(t *testing.T) {
	k := testTokenKey()
	now := time.Unix(1_800_000_000, 0)
	clock := func() time.Time { return now }
	r := NewRefresher(k, testSandboxClaims(time.Time{}), clock)
	first, err := r.Token()
	if err != nil {
		t.Fatal(err)
	}
	now = time.Unix(1_800_000_000, 0).Add(420 * time.Second) // 70% of 600 s elapsed: exactly 30% remains
	same, _ := r.Token()
	if same != first {
		t.Fatal("re-minted with 30% of the TTL remaining")
	}
	now = now.Add(time.Second)
	next, err := r.Token()
	if err != nil || next == first {
		t.Fatalf("not re-minted with under 30%% remaining: %v", err)
	}
	if _, c := decodeJWS(t, next); c["iat"] != float64(now.Unix()) {
		t.Errorf("new token iat %v", c["iat"])
	}
}

// TestTokenVerifiesInTheMocaRelay is the Go/TS contract check: the moca control plane's own
// verifiers must accept what this file mints.
func TestTokenVerifiesInTheMocaRelay(t *testing.T) {
	moca := os.Getenv("E15_MOCA")
	if moca == "" {
		t.Skip("E15_MOCA is not set: point it at a moca checkout to run the Go/TS token contract test")
	}
	if _, err := os.Stat(filepath.Join(moca, "packages/control-plane/src/sandbox-token.ts")); err != nil {
		t.Skipf("E15_MOCA=%s has no control-plane sandbox-token.ts", moca)
	}
	for _, bin := range []string{"node", "npx"} {
		if _, err := exec.LookPath(bin); err != nil {
			t.Skipf("%s not on PATH", bin)
		}
	}
	k := testTokenKey()
	now := time.Now()
	sb, err := k.MintSandbox(testSandboxClaims(now))
	if err != nil {
		t.Fatal(err)
	}
	sm, err := k.MintSetMode(SetModeClaims{Iss: "e17b-issuer", Sub: "driver", Sbx: "sbx-1", Wrk: "worker-1",
		Mode: "lease", ModeEpoch: 1, IdleTimeoutS: 120, TTL: 300 * time.Second, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	// Flip one bit of the signature of a copy.
	parts := strings.Split(sb, ".")
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sig[0] ^= 1
	bad := parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(sig)

	in, _ := json.Marshal(map[string]string{"keyset": k.PublicKeyset(), "issuer": "e17b-issuer",
		"sandbox": sb, "setMode": sm, "flipped": bad})
	dir := t.TempDir()
	inPath := filepath.Join(dir, "in.json")
	if err := os.WriteFile(inPath, in, 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "verify.ts")
	src := `import { readFileSync } from 'node:fs';
import { verifySandboxToken, verifySetModeToken } from '` + moca + `/packages/control-plane/src/sandbox-token.ts';
import { parseKeyset } from '` + moca + `/packages/control-plane/src/token.ts';
const i = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const keys = parseKeyset(i.keyset);
const opts = { issuer: i.issuer };
const sb = verifySandboxToken(i.sandbox, keys, opts);
if (sb.wsk !== sb.sbx || sb.mode !== 'lease' || sb.mode_epoch !== 1) throw new Error('sandbox claims ' + JSON.stringify(sb));
const sm = verifySetModeToken(i.setMode, keys, opts);
if (sm.mode_epoch !== 1) throw new Error('set-mode claims');
let refused = false;
try { verifySandboxToken(i.flipped, keys, opts); } catch { refused = true; }
if (!refused) throw new Error('flipped signature accepted');
let wrongTyp = false;
try { verifySandboxToken(i.setMode, keys, opts); } catch { wrongTyp = true; }
if (!wrongTyp) throw new Error('set-mode token accepted as an exec token');
console.log('OK');
`
	if err := os.WriteFile(script, []byte(src), 0o600); err != nil {
		t.Fatal(err)
	}
	// The script lives in a temp dir; tsx and the moca modules resolve from the moca checkout.
	cmd := exec.Command("npx", "--no-install", "tsx", script, inPath)
	cmd.Dir = filepath.Join(moca, "packages/control-plane")
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "OK") {
		t.Fatalf("moca verifiers refused the Go tokens: %v\n%s", err, out)
	}
}

func tokenExp(t *testing.T, tok string) time.Time {
	t.Helper()
	_, c := decodeJWS(t, tok)
	exp, ok := c["exp"].(float64)
	if !ok {
		t.Fatalf("token has no exp: %v", c)
	}
	return time.Unix(int64(exp), 0)
}

// E17B-R34: an Exec token always outlives the call it carries. TokenFor(timeout) hands out the held
// token only while its exp is at least now + timeout + 60 s (the relay cuts at exp + 30 s, past the
// driver's own deadline of timeout + 30 s); otherwise it mints one with TTL max(base, timeout + 120 s).
func TestRefresherTokenForOutlivesTheCall(t *testing.T) {
	k := testTokenKey()
	now := time.Unix(1_800_000_000, 400_000_000)
	clock := func() time.Time { return now }
	c := testSandboxClaims(time.Time{})
	c.TTL = 300 * time.Second
	r := NewRefresher(k, c, clock)

	// A short call (timeout 121 s) on a fresh base token: the base TTL covers it.
	short := 121 * time.Second
	tok, err := r.TokenFor(short)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := tokenExp(t, tok), time.Unix(now.Unix()+300, 0); !got.Equal(want) {
		t.Fatalf("short call: exp %v, want the base TTL's %v", got, want)
	}
	if again, _ := r.TokenFor(short); again != tok {
		t.Fatal("a token that covers the call was re-minted")
	}

	// A call longer than the base TTL (the metal default corpus's longest, 1,034,568 ms, + 120 s).
	long := (1035 + 120) * time.Second
	ltok, err := r.TokenFor(long)
	if err != nil || ltok == tok {
		t.Fatalf("a call longer than the base TTL reused the base token: %v", err)
	}
	lexp := tokenExp(t, ltok)
	if lexp.Before(now.Add(long + 60*time.Second)) {
		t.Fatalf("long call: exp %v is before send + timeout + 60 s = %v", lexp, now.Add(long+60*time.Second))
	}
	if _, cl := decodeJWS(t, ltok); cl["exp"].(float64)-cl["iat"].(float64) != (long + 120*time.Second).Seconds() {
		t.Fatalf("long call: TTL %v s, want timeout + 120 s", cl["exp"].(float64)-cl["iat"].(float64))
	}

	// The long token still covers a later short call: reused.
	now = now.Add(600 * time.Second)
	if again, _ := r.TokenFor(short); again != ltok {
		t.Fatal("the long token, which still covers the call, was re-minted")
	}
	// The boundary, on a call whose need (timeout + 60 s = 660 s) is above 30% of the held TTL
	// (382 s), so the 30% rule does not decide it: exp exactly now + timeout + 60 s is enough; one
	// second less is not.
	mid := 600 * time.Second
	now = lexp.Add(-mid - 60*time.Second)
	if again, _ := r.TokenFor(mid); again != ltok {
		t.Fatal("re-minted with exp exactly send + timeout + 60 s")
	}
	now = now.Add(time.Second)
	next, err := r.TokenFor(mid)
	if err != nil || next == ltok {
		t.Fatalf("a token with exp < send + timeout + 60 s was handed out: %v", err)
	}
	if got := tokenExp(t, next); got.Before(now.Add(mid + 60*time.Second)) {
		t.Fatalf("re-minted exp %v does not cover the call", got)
	}
	// And the 30% rule still re-mints a token that would cover the call: the held one (TTL 720 s)
	// with 200 s left covers a 121 s call (181 s needed) but is under 30%.
	now = tokenExp(t, next).Add(-200 * time.Second)
	if again, _ := r.TokenFor(short); again == next {
		t.Fatal("the 30% rule no longer applies to TokenFor")
	}
	next, _ = r.TokenFor(short)

	// The 30% rule stays: Token() (status, set_mode, reset) on a held long token is unchanged.
	if tk, _ := r.Token(); tk != next {
		t.Fatal("Token() re-minted a fresh token")
	}
}

// relay-cut arithmetic: the relay's cut (exp + 30 s) must come after the driver's own client
// deadline (timeout + callDeadlineSlackS), so the backend never cuts a call the driver still waits on.
func TestExecTokenOutlivesTheClientDeadline(t *testing.T) {
	if relayCutLeeway != 30*time.Second {
		t.Fatalf("relayCutLeeway %v, want the relay's SANDBOX_CLOCK_LEEWAY_S 30 s", relayCutLeeway)
	}
	if execTokenOutlive+relayCutLeeway <= callDeadlineSlackS*time.Second {
		t.Fatalf("exp + %v leeway with exp >= send + timeout + %v does not outlast the driver's timeout + %d s",
			relayCutLeeway, execTokenOutlive, callDeadlineSlackS)
	}
	if execTokenLongPad < execTokenOutlive {
		t.Fatalf("a token minted for a long call (timeout + %v) would not itself cover it (timeout + %v)", execTokenLongPad, execTokenOutlive)
	}
}

// The relay rule TokenFor is built on, pinned against the moca source: an Exec is cut at
// (claims.exp + leewayS) * 1000, leewayS defaults to SANDBOX_CLOCK_LEEWAY_S, which is 30.
func TestRelayCutRuleMatchesMoca(t *testing.T) {
	moca := os.Getenv("E15_MOCA")
	if moca == "" {
		t.Skip("E15_MOCA is not set: point it at a moca checkout to pin the relay's token-expiry cut")
	}
	for file, want := range map[string]string{
		"packages/sandbox-relay/src/sandbox-caller.ts": "(claims.exp + leewayS) * 1000",
		"packages/sandbox-relay/src/main.ts":           "leewayS: auth.sandboxLeewayS ?? SANDBOX_CLOCK_LEEWAY_S",
		"packages/control-plane/src/sandbox-token.ts":  "export const SANDBOX_CLOCK_LEEWAY_S = 30;",
	} {
		b, err := os.ReadFile(filepath.Join(moca, file))
		if err != nil {
			t.Fatalf("E15_MOCA=%s: %v", moca, err)
		}
		if !strings.Contains(string(b), want) {
			t.Fatalf("%s no longer contains %q: re-check the Exec token rule (E17B-R34)", file, want)
		}
	}
}
