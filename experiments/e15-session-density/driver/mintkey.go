package main

// mint-key subcommand (E17b): `e15-driver mint-key --out DIR` writes a fresh Ed25519 token key
// for one rung. token.key is the PKCS#8 PEM the driver's --token-key reads; token.pub is the
// relay's SH_SANDBOX_TOKEN_PUBLIC_KEYS value (<kid>:<base64 SPKI>) and a newline. Both are mode
// 0600 and created exclusively, so a second mint into the same directory fails instead of
// replacing a key a running relay trusts.

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func mintKeyMain(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("e15-driver mint-key", flag.ContinueOnError)
	fs.SetOutput(stderr)
	out := fs.String("out", "", "directory that receives token.key and token.pub (created 0700 if missing)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *out == "" || fs.NArg() != 0 {
		fmt.Fprintln(stderr, "e15-driver: usage: mint-key --out DIR")
		return 2
	}
	if err := writeMintedKey(*out); err != nil {
		fmt.Fprintf(stderr, "e15-driver: mint-key: %v\n", err)
		return 1
	}
	return 0
}

func writeMintedKey(dir string) error {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	keyPath, pubPath := filepath.Join(dir, "token.key"), filepath.Join(dir, "token.pub")
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if err := writeExclusive(keyPath, pemBytes); err != nil {
		return err
	}
	if err := writeExclusive(pubPath, []byte(TokenKey{Priv: priv}.PublicKeyset()+"\n")); err != nil {
		_ = os.Remove(keyPath) // the key this call just created; never a pre-existing one (O_EXCL)
		return err
	}
	return nil
}

func writeExclusive(path string, b []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
