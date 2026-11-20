package wire

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxEncryptedIdentityDoesNotFallBackWithoutCredential(t *testing.T) {
	dir, cred := t.TempDir(), t.TempDir()
	t.Setenv("CREDENTIALS_DIRECTORY", cred)
	const name = "aurora-identity-key"
	path := filepath.Join(cred, name)
	if err := os.WriteFile(path, bytes.Repeat([]byte{9}, 32), 0o400); err != nil {
		t.Fatal(err)
	}
	_, pin, err := LoadOrCreateCert(dir, "test")
	if err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, "test.key")
	before, err := os.ReadFile(keyPath)
	if err != nil || !bytes.HasPrefix(before, sealedKeyHeader) || bytes.Contains(before, []byte("PRIVATE KEY")) {
		t.Fatalf("key is not protected: %v", err)
	}
	if _, again, err := LoadCert(dir, "test"); err != nil || again != pin {
		t.Fatalf("encrypted identity changed on restart: %v", err)
	}
	t.Setenv("CREDENTIALS_DIRECTORY", "")
	if _, _, err := LoadOrCreateCert(dir, "test"); err == nil {
		t.Fatal("missing key caused a plaintext fallback")
	}
	after, _ := os.ReadFile(keyPath)
	if !bytes.Equal(before, after) {
		t.Fatal("unavailable credential caused identity replacement")
	}
}
