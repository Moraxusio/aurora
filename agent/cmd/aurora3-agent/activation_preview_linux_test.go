package main

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"

	"aurora3/internal/activation"
	"aurora3/internal/entry"
	"aurora3/internal/statecrypt"
	"aurora3/internal/update"
	"aurora3/internal/wire"
)

func TestMain(m *testing.M) {
	if os.Getenv("AURORA_TEST_ACTIVATION_CHILD") == "1" && len(os.Args) == 4 && os.Args[1] == "activation-probe-child" {
		cfg, err := entry.LoadConfig(os.Args[2])
		if err == nil {
			Version = cfg.Name // synthetic signed ELF, not a shipped identity
			err = activationProbeChild(os.Args[2], os.Args[3])
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	os.Exit(m.Run())
}

func TestSignedPreviewActivationPreservesSeparateStateSlots(t *testing.T) {
	t.Setenv("AURORA_TEST_ACTIVATION_CHILD", "1")
	t.Setenv("INVOCATION_ID", "")
	t.Setenv("CREDENTIALS_DIRECTORY", "")
	base := t.TempDir()
	cred, source := filepath.Join(base, "credentials"), filepath.Join(base, "legacy")
	for _, p := range []string{cred, source, filepath.Join(base, "selection"), filepath.Join(base, "policy")} {
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := wire.LoadOrCreateCert(source, "agent"); err != nil {
		t.Fatal(err)
	}
	write := func(p string, b []byte) {
		t.Helper()
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(source, "agent-id"), []byte("0123456789abcdef01234567\n"))
	key := filepath.Join(cred, "aurora-state-key")
	if err := os.WriteFile(key, bytes.Repeat([]byte{17}, 32), 0o400); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CREDENTIALS_DIRECTORY", cred)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	oldTrust := update.TrustedPublicKeys
	update.TrustedPublicKeys = []ed25519.PublicKey{pub}
	defer func() { update.TrustedPublicKeys = oldTrust }()
	policy := func(revoked ...string) {
		t.Helper()
		b, sig, err := update.SignPolicy(update.Policy{Product: update.ProductAgent, Channel: update.ChannelStable, Created: "fixture", Revoked: revoked}, priv)
		if err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(base, "policy", "policy.json"), b)
		write(filepath.Join(base, "policy", "policy.sig"), update.SignatureText(sig))
	}
	policy()
	self, err := os.Open(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	defer self.Close()
	token := wire.NewToken()
	program := func(version string) activation.Program {
		t.Helper()
		_, err := self.Seek(0, io.SeekStart)
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(self)
		if err != nil {
			t.Fatal(err)
		}
		b = append(b, []byte(version)...) // distinct ELF bytes per fixture version
		sum := update.HashBytes(b)
		dir := filepath.Join(base, "programs", sum)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		file := "fixture-linux-elf"
		raw, sig, err := update.Sign(update.Manifest{Product: update.ProductAgent, Channel: releaseChannel,
			Version: version, File: file, Size: int64(len(b)), SHA256: sum, Created: "fixture"}, priv)
		if err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(dir, "manifest.json"), raw)
		write(filepath.Join(dir, "manifest.sig"), update.SignatureText(sig))
		if err := os.WriteFile(filepath.Join(dir, file), b, 0o700); err != nil {
			t.Fatal(err)
		}
		fixtures := filepath.Join(base, "fixtures")
		if err := os.MkdirAll(fixtures, 0o700); err != nil {
			t.Fatal(err)
		}
		final := filepath.Join(fixtures, sum)
		conf := &entry.Config{Name: version, Token: token, StateDir: source,
			Roots: []entry.Root{{ID: "workspace", Path: source}}}
		if err := statecrypt.CloneDirectory(source, final, func(stage string, _ []string) error {
			_, _, err := entry.CloneLinuxIdentity(conf, stage, final, "actpreview")
			return err
		}); err != nil {
			t.Fatal(err)
		}
		return activation.Program{Version: version, SHA256: sum}
	}
	old, next := program("4.0.0"), program("4.0.1")
	use := func(mode string, p activation.Program) error {
		return activationPreview([]string{mode, "--root", base, "--version", p.Version, "--sha256", p.SHA256})
	}
	if err := use("init", old); err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(base, "fixtures", old.SHA256, "agent.json")
	before, err := os.ReadFile(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := use("trial", next); err != nil {
		t.Fatal(err)
	}
	store := &activation.Store{Dir: filepath.Join(base, "selection"), Verify: func(p activation.Program) error {
		_, err := activation.LinuxProgram(base, p, releaseChannel)
		return err
	}}
	actual, err := store.SelectOnBoot()
	if err != nil || actual != next {
		t.Fatal("boot did not select the confirmed version", actual, err)
	}
	r, err := store.ReadReceipt()
	if err != nil || r.Previous == nil || *r.Previous != old || r.Receipt.State != "confirmed" {
		t.Fatal("missing durable confirmation", r, err)
	}
	after, err := os.ReadFile(original)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("trial changed the previous version's state")
	}
	policy(next.Version)
	if _, err := store.SelectOnBoot(); err == nil || errors.Is(err, os.ErrNotExist) {
		t.Fatal("revocation was not applied")
	}
}
