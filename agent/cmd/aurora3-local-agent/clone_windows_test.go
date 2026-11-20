package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
	"github.com/hashicorp/yamux"
)

func TestProtectedLocalMigrationAndRestart(t *testing.T) {
	if os.Getenv("AURORA_LOCAL_PROTECTION_HELPER") == "1" {
		if err := run(); err != nil {
			os.Exit(9)
		}
		os.Exit(0)
	}
	base := t.TempDir()
	source, clone := filepath.Join(base, "legacy"), filepath.Join(base, "clone")
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	type readyInfo struct {
		Addr, Pin, Token string
		Protected        bool `json:"protected_state"`
	}
	start := func(dir string, protected, accepted bool) (readyInfo, func()) {
		t.Helper()
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestProtectedLocalMigrationAndRestart$")
		cmd.Env = append(os.Environ(), "AURORA_LOCAL_PROTECTION_HELPER=1")
		if path := os.Getenv("AURORA_LEGACY_LOCAL_BINARY"); dir == source && path != "" {
			cmd = exec.CommandContext(ctx, path)
		}
		if path := os.Getenv("AURORA_PREVIEW_LOCAL_BINARY"); dir != source && path != "" {
			cmd = exec.CommandContext(ctx, path)
		}
		in, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		out, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = cmd.Process.Kill() })
		if err := json.NewEncoder(in).Encode(map[string]any{"state_dir": dir, "protected_state": protected}); err != nil {
			t.Fatal(err)
		}
		var ready readyInfo
		parsed := make(chan error, 1)
		go func() { parsed <- json.NewDecoder(bufio.NewReader(out)).Decode(&ready) }()
		select {
		case err = <-parsed:
		case <-time.After(10 * time.Second):
			t.Fatal("protected bootstrap timed out")
		}
		if !accepted {
			_ = in.Close()
			if err != io.EOF || cmd.Wait() == nil {
				t.Fatal("invalid or busy state was allowed to listen")
			}
			return ready, func() {}
		}
		if err != nil || ready.Protected != protected {
			t.Fatalf("bootstrap failed: %v", err)
		}
		return ready, func() {
			t.Helper()
			_ = in.Close()
			if err := cmd.Wait(); err != nil {
				t.Fatal(err)
			}
		}
	}
	legacy, stopLegacy := start(source, false, true)
	stopLegacy()
	fresh := filepath.Join(base, "fresh")
	if err := os.Mkdir(fresh, 0o700); err != nil {
		t.Fatal(err)
	}
	first, stopFresh := start(fresh, true, true)
	stopFresh()
	if key, err := os.ReadFile(filepath.Join(fresh, statecrypt.KeyFile)); err != nil || !bytes.HasPrefix(key, []byte("AURORA-STATE-DPAPI\x01")) {
		t.Fatal("new Windows state key was not protected", err)
	}
	second, stopFresh := start(fresh, true, true)
	stopFresh()
	if second.Pin != first.Pin {
		t.Fatal("fresh Windows identity changed on restart")
	}
	id, err := os.ReadFile(filepath.Join(source, "agent-id"))
	if err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(source, "ai", "sessions", "fixture.json")
	if err := os.MkdirAll(filepath.Dir(sessionPath), 0o700); err != nil {
		t.Fatal(err)
	}
	const title = "synthetic private notes"
	const attachment = "att_0123456789abcdef01234567"
	body := []byte("synthetic attachment body")
	digest := sha256.Sum256(body)
	attachDir := filepath.Join(source, "ai", "attachments")
	if err := os.Mkdir(attachDir, 0o700); err != nil {
		t.Fatal(err)
	}
	meta, err := json.Marshal(map[string]any{
		"id": attachment, "name": "secret.txt", "mime": "text/plain",
		"size": len(body), "sha256": hex.EncodeToString(digest[:]),
	})
	if err != nil {
		t.Fatal(err)
	}
	for ext, b := range map[string][]byte{".bin": body, ".json": meta} {
		if err := os.WriteFile(filepath.Join(attachDir, attachment+ext), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	legacyJSON := []byte(`{"id":"fixture","title":"` + title + `","messages":[{"role":"user","parts":[{"type":"file","attachment_id":"` + attachment + `"}]}]}`)
	if err := os.WriteFile(sessionPath, legacyJSON, 0o600); err != nil {
		t.Fatal(err)
	}
	const receiptID = "0123456789abcdef0123456789abcdef"
	receiptPath := filepath.Join(source, "paste-receipts", receiptID+".json")
	if err := os.Mkdir(filepath.Dir(receiptPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(receiptPath, []byte(`{"committed":true,"request":{"id":"`+receiptID+`","to":"/synthetic-private.txt"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshots := filepath.Join(source, "ai", "snapshots")
	if err := os.Mkdir(snapshots, 0o700); err != nil {
		t.Fatal(err)
	}
	unknown := filepath.Join(snapshots, "old-shadow-repo")
	if err := os.Mkdir(unknown, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := cloneProtectedPreview([]string{"--source", source, "--dest", clone, "--source-stopped"}); err == nil {
		t.Fatal("unsupported legacy snapshot would be silently lost")
	}
	if _, err := os.Stat(clone); !os.IsNotExist(err) {
		t.Fatal("a partially migrated state was published")
	}
	if err := os.Remove(unknown); err != nil {
		t.Fatal(err)
	}
	if err := cloneProtectedPreview([]string{"--source", source, "--dest", clone, "--source-stopped"}); err != nil {
		t.Fatal(err)
	}
	old, err := os.ReadFile(sessionPath)
	if err != nil || !bytes.Equal(old, legacyJSON) {
		t.Fatal("legacy store changed")
	}
	stored, err := os.ReadFile(filepath.Join(clone, "ai", "sessions", "fixture.json"))
	if err != nil || !statecrypt.Protected(stored) || bytes.Contains(stored, []byte(title)) {
		t.Fatal("session was not encrypted in the clone")
	}
	release, err := statecrypt.LockWriter(clone)
	if err != nil {
		t.Fatal(err)
	}
	codec, err := entry.PrepareLocalProtection(clone)
	release()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(clone, "ai", "attachments", attachment+".bin"))
	if err != nil || !statecrypt.Protected(content) || bytes.Contains(content, body) {
		t.Fatal("attachment was not encrypted in the clone")
	}
	recovered, err := codec.Open("ai:attachment-data:"+attachment+".bin", content)
	if err != nil || !bytes.Equal(recovered, body) {
		t.Fatal("protected attachment contents changed", err)
	}
	cloneID, err := os.ReadFile(filepath.Join(clone, "agent-id"))
	if err != nil || !bytes.Equal(id, cloneID) {
		t.Fatal("agent ID changed in the clone")
	}
	for range 2 {
		info, stop := start(clone, true, true)
		if info.Pin != legacy.Pin {
			t.Fatal("legacy pin changed on restart")
		}
		start(clone, true, false)
		socket, err := net.DialTimeout("tcp", info.Addr, 5*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		conn := tls.Client(socket, wire.PinnedTLS(info.Pin))
		if err := wire.WriteJSON(conn, wire.Hello{Role: wire.RoleClient, Version: wire.Version, Token: info.Token}); err != nil {
			t.Fatal(err)
		}
		var hello wire.HelloReply
		if err := wire.ReadJSON(conn, &hello); err != nil || !hello.OK {
			t.Fatal("protected TLS handshake failed", err)
		}
		mux, err := yamux.Client(conn, wire.MuxConfig())
		if err != nil {
			t.Fatal(err)
		}
		var sessions json.RawMessage
		if err := wire.Call(ctx, wire.NewMux(mux, nil), "ai.sessions", nil, &sessions); err != nil || !bytes.Contains(sessions, []byte(title)) {
			t.Fatalf("protected session is not visible: %v", err)
		}
		var receipt json.RawMessage
		if err := wire.Call(ctx, wire.NewMux(mux, nil), "fs.paste.status", map[string]string{"id": receiptID}, &receipt); err != nil ||
			!bytes.Contains(receipt, []byte("/synthetic-private.txt")) {
			t.Fatalf("protected receipt is not queryable: %v", err)
		}
		mux.Close()
		stop()
	}
	start(clone, false, false)
	key := filepath.Join(clone, statecrypt.KeyFile)
	before, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(key, key+".offline"); err != nil {
		t.Fatal(err)
	}
	start(clone, true, false)
	start(clone, false, false)
	if _, err := os.Stat(key); !os.IsNotExist(err) {
		t.Fatal("missing key was replaced")
	}
	backup, err := os.ReadFile(key + ".offline")
	if err != nil || !bytes.Equal(before, backup) {
		t.Fatal("offline key changed")
	}
	again, stop := start(source, false, true)
	stop()
	if again.Pin != legacy.Pin {
		t.Fatal("legacy rollback source pairing changed")
	}
}
