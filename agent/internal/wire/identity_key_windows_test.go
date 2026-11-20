package wire

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestNewWindowsIdentityKeyUsesDPAPI(t *testing.T) {
	dir := t.TempDir()
	_, pin, err := LoadOrCreateCert(dir, "test")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "test.key")
	b, err := os.ReadFile(path)
	if err != nil || !bytes.HasPrefix(b, dpapiKeyHeader) || bytes.Contains(b, []byte("PRIVATE KEY")) {
		t.Fatalf("key is not DPAPI protected: %v", err)
	}
	_, again, err := LoadCert(dir, "test")
	if err != nil || again != pin {
		t.Fatalf("encrypted identity changed after reopen: %v", err)
	}
	b = b[:len(dpapiKeyHeader)+1]
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadOrCreateCert(dir, "test"); err == nil {
		t.Fatal("damaged protected key was accepted")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(after, b) {
		t.Fatal("damaged protected key overwritten")
	}
}
