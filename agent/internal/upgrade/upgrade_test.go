package upgrade

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/update"
	"aurora3/internal/wire"
)

func signed(t *testing.T, data []byte) (Request, func()) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	old := update.TrustedPublicKeys
	update.TrustedPublicKeys = []ed25519.PublicKey{pub}
	m := update.Manifest{Product: update.ProductAgent, Channel: update.ChannelStable, Version: "3.3.1", File: "aurora3-agent-3.3.1-linux-amd64", Size: int64(len(data)), SHA256: update.HashBytes(data), Created: "2026-11-09"}
	b, s, err := update.Sign(m, key)
	if err != nil {
		t.Fatal(err)
	}
	p, ps, err := update.SignPolicy(update.Policy{Product: update.ProductAgent, Channel: update.ChannelStable, Created: "2026-11-09"}, key)
	if err != nil {
		t.Fatal(err)
	}
	return Request{Manifest: b, Signature: string(update.SignatureText(s)), Policy: p, PolicySignature: string(update.SignatureText(ps))}, func() { update.TrustedPublicKeys = old }
}

func TestSignedUploadAndSanitizedPersistentReceipt(t *testing.T) {
	data := bytes.Repeat([]byte("ELF-test"), 8192)
	req, restore := signed(t, data)
	defer restore()
	var launched string
	e := &Env{StateDir: t.TempDir(), Version: "3.3.0", Arch: "amd64", Gate: &update.Gate{}, Quiet: time.Millisecond, Launch: func(d string) error { launched = d; return nil }}
	a, b := net.Pipe()
	defer a.Close()
	done := make(chan error, 1)
	raw, _ := json.Marshal(req)
	go func() { defer b.Close(); done <- e.upload(context.Background(), b, raw) }()
	var r wire.Response
	if err := wire.ReadJSON(a, &r); err != nil || !r.OK {
		t.Fatal(r, err)
	}
	if err := wire.WriteFrame(a, wire.TypeData, data); err != nil {
		t.Fatal(err)
	}
	_ = wire.WriteFrame(a, wire.TypeEnd, nil)
	if err := wire.ReadJSON(a, &r); err != nil || !r.OK {
		t.Fatal(r, err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(launched, "agent"))
	if !bytes.Equal(got, data) {
		t.Fatal("candidate differs")
	}
	j := Job{}
	_ = json.Unmarshal(r.Result, &j)
	if j.ID == "" || j.State != "starting" {
		t.Fatal(j)
	}
	j.State = "upgraded"
	if err := WriteJob(launched, j); err != nil {
		t.Fatal(err)
	}
	// A fresh service instance can read the receipt after restart.
	newEnv := &Env{StateDir: e.StateDir}
	arg, _ := json.Marshal(map[string]string{"id": j.ID})
	res, err := newEnv.status(context.Background(), arg)
	if err != nil || res.(Job).State != "upgraded" {
		t.Fatal(res, err)
	}
	if _, err = newEnv.status(context.Background(), json.RawMessage(`{"id":"../../agent.json"}`)); err == nil {
		t.Fatal("path escape accepted")
	}
}

func TestBadUploadNeverLaunchesAndCanRetry(t *testing.T) {
	data := []byte("candidate")
	req, restore := signed(t, data)
	defer restore()
	called := false
	e := &Env{StateDir: t.TempDir(), Version: "3.3.0", Arch: "amd64", Quiet: time.Millisecond, Launch: func(string) error { called = true; return nil }}
	a, b := net.Pipe()
	done := make(chan error, 1)
	raw, _ := json.Marshal(req)
	go func() { defer b.Close(); done <- e.upload(context.Background(), b, raw) }()
	var r wire.Response
	_ = wire.ReadJSON(a, &r)
	_ = wire.WriteFrame(a, wire.TypeData, []byte("wrong-data"))
	_ = wire.WriteFrame(a, wire.TypeEnd, nil)
	a.Close()
	if err := <-done; err == nil {
		t.Fatal("tampered bytes accepted")
	}
	if called {
		t.Fatal("launched tampered candidate")
	}
	left, _ := os.ReadDir(filepath.Join(e.StateDir, "upgrades"))
	if len(left) != 0 {
		t.Fatal("partial upload left behind")
	}
	if e.busy {
		t.Fatal("failed upload left permanent busy state")
	}
}

func TestTamperedSignatureAndWrongArchitectureRejected(t *testing.T) {
	req, restore := signed(t, []byte("candidate"))
	defer restore()
	e := &Env{StateDir: t.TempDir(), Version: "3.3.0", Arch: "arm64"}
	raw, _ := json.Marshal(req)
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if err := e.upload(context.Background(), b, raw); err == nil {
		t.Fatal("wrong architecture accepted")
	}
	req.Signature = "AAAA"
	raw, _ = json.Marshal(req)
	e.Arch = "amd64"
	if err := e.upload(context.Background(), b, raw); err == nil {
		t.Fatal("wrong signature accepted")
	}
}

func TestExistingUploadOrWorkerBlocksASecondJob(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "upgrades", "0123456789abcdef01234567"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := WriteJob(filepath.Join(dir, "upgrades", "0123456789abcdef01234567"), Job{ID: "0123456789abcdef01234567", Version: "3.3.1", Previous: "3.3.0", State: StateWaiting}); err != nil {
		t.Fatal(err)
	}
	data := []byte("candidate")
	req, restore := signed(t, data)
	defer restore()
	e := &Env{StateDir: dir, Version: "3.3.0", Arch: "amd64", Launch: func(string) error { t.Fatal("stale job was launched"); return nil }}
	_, b := net.Pipe()
	err := e.upload(context.Background(), b, mustJSON(req))
	_ = b.Close()
	if wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("error=%v code=%s", err, wire.CodeOf(err))
	}
}

func TestExpiredInstallingJobRecordsFailureAndBlocksRetry(t *testing.T) {
	dir := t.TempDir()
	id := "0123456789abcdef01234567"
	jobDir := filepath.Join(dir, "upgrades", id)
	if err := os.MkdirAll(jobDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := WriteJob(jobDir, Job{ID: id, Version: "3.3.1", Previous: "3.3.0", State: StateInstalling}); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(jobDir, "status.json"), old, old); err != nil {
		t.Fatal(err)
	}
	data := []byte("candidate")
	req, restore := signed(t, data)
	defer restore()
	e := &Env{StateDir: dir, Version: "3.3.0", Arch: "amd64", WorkerWait: time.Millisecond, Launch: func(string) error { t.Fatal("expired target was relaunched"); return nil }}
	_, b := net.Pipe()
	err := e.upload(context.Background(), b, mustJSON(req))
	_ = b.Close()
	if wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("error=%v code=%s", err, wire.CodeOf(err))
	}
	bad, err := update.FailureFor(dir, "3.3.1")
	if err != nil || !bad {
		t.Fatalf("failure journal: %v %v", bad, err)
	}
}

func mustJSON(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
