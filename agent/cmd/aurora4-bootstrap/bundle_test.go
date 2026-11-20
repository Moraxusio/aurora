package main

import (
	"archive/zip"
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"aurora3/internal/update"
)

func buildTestBundle(t *testing.T, extras ...string) ([]byte, []byte, []byte) {
	t.Helper()
	buf := &bytes.Buffer{}
	z := zip.NewWriter(buf)
	for _, n := range append([]string{"aurora.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
		"local-agent/windows-amd64/manifest.json", "agent/amd64/manifest.json"}, extras...) {
		f, err := z.Create(n)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write([]byte("test:" + n)); err != nil {
			t.Fatal(err)
		}
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	old := update.TrustedPublicKeys
	update.TrustedPublicKeys = []ed25519.PublicKey{pub}
	t.Cleanup(func() { update.TrustedPublicKeys = old })
	p := buf.Bytes()
	m, sig, err := update.Sign(update.Manifest{Product: runtimeProduct, Channel: update.ChannelStable,
		Version: "4.0.0", File: "aurora4-runtime-4.0.0-windows-amd64.exe",
		Size: int64(len(p)), SHA256: update.HashBytes(p), Created: "fixture"}, priv)
	if err != nil {
		t.Fatal(err)
	}
	return p, m, sig
}

func TestRuntimeAuthenticatesBundleAndRejectsCacheTampering(t *testing.T) {
	p, m, sig := buildTestBundle(t, "data/文件.txt")
	z, _, err := openBundle(p, m, sig, "4.0.0")
	if err != nil {
		t.Fatal(err)
	}
	orig := append([]byte(nil), p...)
	p[0] ^= 1
	if _, _, err := openBundle(p, m, sig, "4.0.0"); err == nil {
		t.Fatal("altered embedded payload accepted")
	}
	copy(p, orig)
	dir := t.TempDir()
	if err := unpackRuntime(z, dir); err != nil {
		t.Fatal(err)
	}
	check := func() error {
		return verifyRuntime(z, dir, func(_ string, fi fs.FileInfo) bool { return fi.Mode()&os.ModeSymlink != 0 })
	}
	if err := check(); err != nil {
		t.Fatal(err)
	}
	dll := filepath.Join(dir, "added.dll")
	if err := os.WriteFile(dll, []byte("unexpected"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := check(); err == nil {
		t.Fatal("unexpected DLL accepted")
	}
	if err := os.Remove(dll); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "aurora.exe"), []byte("TEST:aurora.exe"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := check(); err == nil {
		t.Fatal("same-size mutation accepted")
	}
}

func TestRuntimeRejectsUnsafeAndAmbiguousArchivePaths(t *testing.T) {
	for _, path := range []string{"../outside", `data\bad`, "data/file:stream", "data/COM1.log",
		"Data/mixed", "data/trailing.", "aurora.exe", "DATA/App.so", "data/app.so/child"} {
		t.Run(path, func(t *testing.T) {
			p, m, sig := buildTestBundle(t, path)
			if _, _, err := openBundle(p, m, sig, "4.0.0"); err == nil {
				t.Fatal("unsafe archive accepted")
			}
		})
	}
}
