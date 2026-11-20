package statecrypt

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCredentialRequiresASeparatePrivateRegularKey(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CREDENTIALS_DIRECTORY", "")
	if _, err := Credential(); err == nil {
		t.Fatal("missing directory was accepted")
	}
	t.Setenv("CREDENTIALS_DIRECTORY", dir)
	path := filepath.Join(dir, "aurora-state-key")
	key := bytes.Repeat([]byte{17}, KeyBytes)
	if err := os.WriteFile(path, key, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Credential(); err == nil {
		t.Fatal("world-readable credential was accepted")
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	first, err := Credential()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, path+".original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path+".original", path); err != nil {
		t.Fatal(err)
	}
	if _, err := Credential(); err == nil {
		t.Fatal("linked credential was accepted")
	}
	expected, err := New(key)
	if err != nil {
		t.Fatal(err)
	}
	if first.ObjectID("fixture", nil) != expected.ObjectID("fixture", nil) {
		t.Fatal("loaded key differs from the provisioned key")
	}
}
