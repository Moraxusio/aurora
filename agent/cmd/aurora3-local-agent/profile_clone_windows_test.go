package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"aurora3/internal/statecrypt"
)

func TestClientPreviewClonesOnlyVerifiedDPAPICiphertext(t *testing.T) {
	base := t.TempDir()
	source, clone := filepath.Join(base, "original"), filepath.Join(base, "clone")
	for _, part := range []string{"documents", "development"} {
		if err := os.MkdirAll(filepath.Join(source, part), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	record := func(relative, secret string, profile bool) []byte {
		t.Helper()
		b, err := statecrypt.UserDPAPI([]byte(secret), []byte(clientDPAPIPurpose), true)
		if err != nil {
			t.Fatal(err)
		}
		if profile {
			b = append([]byte(profileDPAPIHeader), b...)
		}
		if err := os.WriteFile(filepath.Join(source, relative), b, 0o600); err != nil {
			t.Fatal(err)
		}
		return b
	}
	hash := func(value string) string {
		h := sha256.Sum256([]byte(value))
		return hex.EncodeToString(h[:])
	}
	doc := filepath.Join("documents", hash(`["fixture","root","/示例.txt"]`)+".doc")
	dev := filepath.Join("development", hash("fixture")+".dev")
	expected := map[string][]byte{
		"profile.bin": record("profile.bin", `{"servers":[],"synthetic":"secret-value"}`, true),
		doc:           record(doc, `{"format":1,"key":{"server":"fixture","root":"root","path":"/示例.txt"},"text":"secret-value"}`, false),
		dev:           record(dev, `{"version":1,"server":"fixture","sections":{"draft":"secret-value"}}`, false),
	}
	bad := filepath.Join(source, "documents", hash("misplaced")+".doc")
	if err := os.WriteFile(bad, expected[doc], 0o600); err != nil {
		t.Fatal(err)
	}
	cloneArgs := []string{"--source", source, "--dest", clone, "--source-stopped"}
	if err := cloneClientPreview(cloneArgs); err == nil {
		t.Fatal("misplaced recovery record was accepted")
	}
	if _, err := os.Stat(clone); !os.IsNotExist(err) {
		t.Fatal("partial clone was published")
	}
	if err := os.Remove(bad); err != nil {
		t.Fatal(err)
	}
	if err := cloneClientPreview(cloneArgs); err != nil {
		t.Fatal(err)
	}
	for name, want := range expected {
		for _, dir := range []string{source, clone} {
			b, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil || !bytes.Equal(b, want) || bytes.Contains(b, []byte("secret-value")) {
				t.Fatalf("%s not preserved as original ciphertext: %v", name, err)
			}
		}
	}
	if err := cloneClientPreview(cloneArgs); err == nil {
		t.Fatal("existing client clone was overwritten")
	}
}
