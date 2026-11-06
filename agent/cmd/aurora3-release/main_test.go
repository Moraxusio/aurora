package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aurora3/internal/update"
)

func testKey(t *testing.T) (string, ed25519.PublicKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "test.key")
	if err := os.WriteFile(p, []byte(base64.StdEncoding.EncodeToString(priv)), 0o600); err != nil {
		t.Fatal(err)
	}
	old := update.TrustedPublicKeys
	t.Cleanup(func() { update.TrustedPublicKeys = old })
	update.TrustedPublicKeys = []ed25519.PublicKey{pub}
	return p, pub
}

func signed(t *testing.T, key string) string {
	t.Helper()
	d := t.TempDir()
	bin := filepath.Join(d, "aurora3-agent")
	if err := os.WriteFile(bin, []byte("agent bytes"), 0o755); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(d, "release")
	var b bytes.Buffer
	if err := signCmd([]string{"--key", key, "--version", "3.0.1", "--arch", "amd64", "--file", bin, "--out", out}, &b); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(b.String(), "aurora3-agent-3.0.1-linux-amd64 3.0.1 11 ") {
		t.Fatalf("sign output %q", b.String())
	}
	return out
}

func TestSignAndVerify(t *testing.T) {
	key, _ := testKey(t)
	dir := signed(t, key)
	var b bytes.Buffer
	if err := verifyCmd([]string{"--dir", dir}, &b); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"product: aurora3-agent", "channel: stable", "version: 3.0.1", "file: aurora3-agent-3.0.1-linux-amd64", "size: 11"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("missing %q in %s", want, b.String())
		}
	}
}

func TestVerifyRejects(t *testing.T) {
	key, _ := testKey(t)
	cases := map[string]func(dir string){
		"build byte": func(dir string) { flip(t, filepath.Join(dir, "aurora3-agent-3.0.1-linux-amd64"), 2) },
		"manifest":   func(dir string) { flip(t, filepath.Join(dir, "manifest.json"), 12) },
		"signature": func(dir string) {
			b, _ := os.ReadFile(filepath.Join(dir, "manifest.sig"))
			s, _ := update.DecodeSignature(b)
			s[0] ^= 1
			_ = os.WriteFile(filepath.Join(dir, "manifest.sig"), update.SignatureText(s), 0o644)
		},
		"missing build": func(dir string) { _ = os.Remove(filepath.Join(dir, "aurora3-agent-3.0.1-linux-amd64")) },
	}
	for name, spoil := range cases {
		t.Run(name, func(t *testing.T) {
			dir := signed(t, key)
			spoil(dir)
			if _, err := verifyDir(update.ProductAgent, update.ChannelStable, dir); err == nil {
				t.Fatal("accepted")
			}
		})
	}
	t.Run("other product", func(t *testing.T) {
		dir := signed(t, key)
		if _, err := verifyDir("aurora-agent", update.ChannelStable, dir); err == nil || !strings.Contains(err.Error(), "product") {
			t.Fatalf("v2 product name accepted: %v", err)
		}
	})
	t.Run("untrusted key", func(t *testing.T) {
		dir := signed(t, key)
		other, _, _ := ed25519.GenerateKey(rand.Reader)
		update.TrustedPublicKeys = []ed25519.PublicKey{other}
		if _, err := verifyDir(update.ProductAgent, update.ChannelStable, dir); err == nil {
			t.Fatal("accepted")
		}
	})
}

func TestSignRefusesBadInput(t *testing.T) {
	key, _ := testKey(t)
	bin := filepath.Join(t.TempDir(), "b")
	_ = os.WriteFile(bin, []byte("x"), 0o755)
	for name, args := range map[string][]string{
		"dev version": {"--key", key, "--version", "3.0.0-dev", "--arch", "amd64", "--file", bin, "--out", t.TempDir()},
		"bad arch":    {"--key", key, "--version", "3.0.1", "--arch", "386", "--file", bin, "--out", t.TempDir()},
		"no key":      {"--version", "3.0.1", "--arch", "amd64", "--file", bin, "--out", t.TempDir()},
	} {
		if err := signCmd(args, &bytes.Buffer{}); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestPubkey(t *testing.T) {
	key, pub := testKey(t)
	var b bytes.Buffer
	if err := pubkeyCmd([]string{"--key", key}, &b); err != nil {
		t.Fatal(err)
	}
	want := base64.StdEncoding.EncodeToString(pub) + "\n" + update.KeyID(pub) + "\n"
	if b.String() != want {
		t.Fatalf("%q, want %q", b.String(), want)
	}
}

func flip(t *testing.T, path string, at int) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	b[at] ^= 1
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}
