package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMintKeyWritesKeyAndKeyset(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tok")
	var buf bytes.Buffer
	if code := realMain([]string{"mint-key", "--out", dir}, func(string) string { return "" }, &buf); code != 0 {
		t.Fatalf("mint-key exit %d: %s", code, buf.String())
	}
	for name, want := range map[string]os.FileMode{"token.key": 0o600, "token.pub": 0o600} {
		st, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != want {
			t.Errorf("%s mode %v, want %v", name, st.Mode().Perm(), want)
		}
	}
	k, err := LoadTokenKey(filepath.Join(dir, "token.key"))
	if err != nil {
		t.Fatalf("token.key does not load as PKCS#8 PEM: %v", err)
	}
	pub, err := os.ReadFile(filepath.Join(dir, "token.pub"))
	if err != nil {
		t.Fatal(err)
	}
	if string(pub) != k.PublicKeyset()+"\n" {
		t.Errorf("token.pub = %q, want %q", pub, k.PublicKeyset()+"\n")
	}
	if strings.Count(string(pub), "\n") != 1 {
		t.Errorf("token.pub must be one line: %q", pub)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Errorf("the key directory mode %v, want 0700", st.Mode().Perm())
	}
}

func TestMintKeyRefusesToOverwrite(t *testing.T) {
	dir := t.TempDir()
	get := func(string) string { return "" }
	var buf bytes.Buffer
	if code := realMain([]string{"mint-key", "--out", dir}, get, &buf); code != 0 {
		t.Fatalf("first mint exit %d: %s", code, buf.String())
	}
	before, _ := os.ReadFile(filepath.Join(dir, "token.key"))
	buf.Reset()
	if code := realMain([]string{"mint-key", "--out", dir}, get, &buf); code == 0 {
		t.Fatal("a second mint into the same directory must fail")
	}
	after, _ := os.ReadFile(filepath.Join(dir, "token.key"))
	if !bytes.Equal(before, after) {
		t.Error("the existing key was overwritten")
	}
}

func TestMintKeyNeedsOut(t *testing.T) {
	var buf bytes.Buffer
	if code := realMain([]string{"mint-key"}, func(string) string { return "" }, &buf); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
}
