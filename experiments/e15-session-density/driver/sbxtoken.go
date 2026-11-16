package main

// Sandbox and set-mode token minter (E17b). Opt-in: nothing in the driver calls it unless a
// caller builds a TokenKey. The format is the moca control plane's packages/control-plane/src/
// sandbox-token.ts and token.ts (signJws, keyIdFor); TestTokenVerifiesInTheMocaRelay checks that
// the two agree.

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	sandboxTokenTyp     = "moca-sandbox+jwt"
	setModeTokenTyp     = "moca-sandbox-mode+jwt"
	sandboxTokenAud     = "moca-sandbox"
	setModeTokenMaxTTL  = 300 * time.Second // SANDBOX_MODE_TOKEN_TTL_S
	refreshRemainingPct = 30                // re-mint when less than this share of the TTL remains
)

// TokenKey is the Ed25519 key whose public half the relay lists in SH_SANDBOX_TOKEN_PUBLIC_KEYS.
type TokenKey struct{ Priv ed25519.PrivateKey }

func (k TokenKey) spki() []byte {
	der, err := x509.MarshalPKIXPublicKey(k.Priv.Public())
	if err != nil { // cannot happen for an ed25519 key
		panic(err)
	}
	return der
}

// Kid is hex(sha256(SPKI DER))[:16], the relay's keyIdFor; the relay rejects a mismatching kid.
func (k TokenKey) Kid() string {
	sum := sha256.Sum256(k.spki())
	return hex.EncodeToString(sum[:8])
}

// PublicKeyset is the SH_SANDBOX_TOKEN_PUBLIC_KEYS entry: <kid>:<base64 SPKI DER>.
func (k TokenKey) PublicKeyset() string {
	return k.Kid() + ":" + base64.StdEncoding.EncodeToString(k.spki())
}

// SandboxClaims is the input of an Exec token. Iss has no default: the relay refuses to boot with
// a keyset and no SH_SANDBOX_TOKEN_ISSUER, and the two must match. Now zero means time.Now().
// wsk is always Sbx. ModeEpoch must equal the epoch of the set_mode the driver sent.
type SandboxClaims struct {
	Iss, Sub, Tenant, Sbx, Wrk string
	Mode                       string
	ModeEpoch, IdleTimeoutS    int
	TTL                        time.Duration
	Now                        time.Time
}

// SetModeClaims is the input of a set-mode token: no tenant and no scope, TTL at most 300 s.
type SetModeClaims struct {
	Iss, Sub, Sbx, Wrk      string
	Mode                    string
	ModeEpoch, IdleTimeoutS int
	TTL                     time.Duration
	Now                     time.Time
}

func (k TokenKey) sign(typ string, claims any) (string, error) {
	h, err := json.Marshal(map[string]string{"alg": "EdDSA", "typ": typ, "kid": k.Kid()})
	if err != nil {
		return "", err
	}
	p, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	b64 := base64.RawURLEncoding
	in := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	return in + "." + b64.EncodeToString(ed25519.Sign(k.Priv, []byte(in))), nil
}

func newJTI() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func checkCommon(iss, sub, sbx, wrk, mode string, epoch, idle int, ttl time.Duration) error {
	if iss == "" || sub == "" || sbx == "" || wrk == "" {
		return errors.New("sbxtoken: iss, sub, sbx and wrk are required")
	}
	if mode == "" {
		return errors.New("sbxtoken: mode is required")
	}
	if epoch < 0 || idle < 0 {
		return errors.New("sbxtoken: mode_epoch and idle_timeout_s must not be negative")
	}
	if ttl < time.Second {
		return errors.New("sbxtoken: TTL must be at least 1 s")
	}
	return nil
}

func nowOr(t time.Time) time.Time {
	if t.IsZero() {
		return time.Now()
	}
	return t
}

// MintSandbox mints the Exec token (typ moca-sandbox+jwt).
func (k TokenKey) MintSandbox(c SandboxClaims) (string, error) {
	if err := checkCommon(c.Iss, c.Sub, c.Sbx, c.Wrk, c.Mode, c.ModeEpoch, c.IdleTimeoutS, c.TTL); err != nil {
		return "", err
	}
	if c.Tenant == "" {
		return "", errors.New("sbxtoken: tenant is required")
	}
	jti, err := newJTI()
	if err != nil {
		return "", err
	}
	iat := nowOr(c.Now).Unix()
	return k.sign(sandboxTokenTyp, map[string]any{
		"iss": c.Iss, "aud": sandboxTokenAud, "sub": c.Sub, "tenant": c.Tenant,
		"sbx": c.Sbx, "wrk": c.Wrk, "wsk": c.Sbx, "scope": []string{"exec"},
		"mode": c.Mode, "mode_epoch": c.ModeEpoch, "idle_timeout_s": c.IdleTimeoutS,
		"iat": iat, "exp": iat + int64(c.TTL/time.Second), "jti": jti,
	})
}

// MintSetMode mints the set_mode token (typ moca-sandbox-mode+jwt).
func (k TokenKey) MintSetMode(c SetModeClaims) (string, error) {
	if err := checkCommon(c.Iss, c.Sub, c.Sbx, c.Wrk, c.Mode, c.ModeEpoch, c.IdleTimeoutS, c.TTL); err != nil {
		return "", err
	}
	if c.TTL > setModeTokenMaxTTL {
		return "", fmt.Errorf("sbxtoken: set-mode TTL %s exceeds %s", c.TTL, setModeTokenMaxTTL)
	}
	jti, err := newJTI()
	if err != nil {
		return "", err
	}
	iat := nowOr(c.Now).Unix()
	return k.sign(setModeTokenTyp, map[string]any{
		"iss": c.Iss, "aud": sandboxTokenAud, "sub": c.Sub,
		"sbx": c.Sbx, "wrk": c.Wrk, "wsk": c.Sbx,
		"mode": c.Mode, "mode_epoch": c.ModeEpoch, "idle_timeout_s": c.IdleTimeoutS,
		"iat": iat, "exp": iat + int64(c.TTL/time.Second), "jti": jti,
	})
}

// Refresher hands out an Exec token and re-mints it once less than 30% of its TTL remains, so a
// session longer than one TTL never presents an expired token. Not safe for concurrent use.
type Refresher struct {
	key    TokenKey
	claims SandboxClaims
	now    func() time.Time
	tok    string
	minted time.Time
}

// NewRefresher takes the claims to mint with (their Now is ignored) and a clock (nil = time.Now).
func NewRefresher(k TokenKey, c SandboxClaims, now func() time.Time) *Refresher {
	if now == nil {
		now = time.Now
	}
	return &Refresher{key: k, claims: c, now: now}
}

// Token returns the current token, minting a new one when none exists or less than 30% of the TTL
// remains.
func (r *Refresher) Token() (string, error) {
	t := r.now()
	if r.tok != "" {
		remaining := r.minted.Add(r.claims.TTL).Sub(t)
		if remaining*100 >= r.claims.TTL*refreshRemainingPct {
			return r.tok, nil
		}
	}
	c := r.claims
	c.Now = t
	tok, err := r.key.MintSandbox(c)
	if err != nil {
		return "", err
	}
	// The token's exp is iat (whole seconds, floored) + TTL, so the clock the 30% is measured on
	// starts at the floored second: on a short TTL the unfloored mint time would let a token be
	// reused up to a second after its exp.
	r.tok, r.minted = tok, t.Truncate(time.Second)
	return tok, nil
}
