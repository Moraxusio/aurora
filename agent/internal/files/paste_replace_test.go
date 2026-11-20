//go:build linux || windows

package files

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"aurora3/internal/filetxn"
	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

func TestPasteReplaceReceiptSurvivesReconnectAndDoesNotReplay(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	ctx := context.Background()
	newEnv := func() *Env {
		return &Env{StateDir: state, Roots: []Root{{ID: "work", Path: root}}, Audit: commitAudit{}}
	}
	e := newEnv()
	write := func(p, value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, p), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	version := func(p string) string {
		t.Helper()
		fi, err := os.Stat(filepath.Join(root, p))
		if err != nil {
			t.Fatal(err)
		}
		return etag(fi)
	}
	assertBytes := func(p, want string) {
		t.Helper()
		if got, err := os.ReadFile(filepath.Join(root, p)); err != nil || string(got) != want {
			t.Fatalf("%s: %q %v (want %q)", p, got, err, want)
		}
	}
	write("src.txt", "source")
	write("dst.txt", "old destination")
	a := replaceRequest{ID: "0123456789abcdef0123456789abcdef", Root: "work", Path: "/src.txt", ToRoot: "work", To: "/dst.txt",
		IfMatch: version("src.txt"), ToIfMatch: version("dst.txt")}
	raw, _ := json.Marshal(a)
	status, _ := json.Marshal(map[string]string{"id": a.ID})
	if _, err := e.fsPasteStatus(ctx, status); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("receipt before submission: %v", err)
	}
	write("dst.txt", "edited before admission")
	if _, err := e.fsPasteReplace(ctx, raw); wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("stale destination was not rejected: %v", err)
	}
	assertBytes("dst.txt", "edited before admission")
	a.ToIfMatch = version("dst.txt")
	raw, _ = json.Marshal(a)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := e.fsPasteReplace(cancelled, raw); err == nil {
		t.Fatal("cancelled replacement succeeded")
	}
	assertBytes("dst.txt", "edited before admission")
	if _, err := e.fsPasteReplace(ctx, raw); err != nil {
		t.Fatal(err)
	}
	// Ignore the response and reopen state as a new agent instance would.
	e = newEnv()
	if err := filetxn.New(state, []string{root}).Recover(); err != nil {
		t.Fatal(err)
	}
	res, err := e.fsPasteStatus(ctx, status)
	if err != nil || !res.(replaceReceipt).Committed {
		t.Fatalf("lost receipt: %v %v", res, err)
	}
	assertBytes("dst.txt", "source")
	assertBytes("src.txt", "source")
	write("dst.txt", "edited after commit")
	if _, err := e.fsPasteReplace(ctx, raw); err != nil {
		t.Fatal(err)
	}
	assertBytes("dst.txt", "edited after commit")
	a.ToIfMatch = version("dst.txt")
	mismatch, _ := json.Marshal(a)
	if _, err := e.fsPasteReplace(ctx, mismatch); wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("receipt ID reused for a different version: %v", err)
	}
}

func TestProtectedPasteReceiptSurvivesAProcessRestart(t *testing.T) {
	state := t.TempDir()
	for _, mode := range []string{"create", "query", "missing-key", "wrong-key"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestProtectedPasteReceiptChild$")
		cmd.Env = append(os.Environ(), "AURORA_RECEIPT_TEST_STATE="+state, "AURORA_RECEIPT_TEST_MODE="+mode)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", mode, err, out)
		}
	}
}

func TestProtectedPasteReceiptChild(t *testing.T) {
	state, mode := os.Getenv("AURORA_RECEIPT_TEST_STATE"), os.Getenv("AURORA_RECEIPT_TEST_MODE")
	if state == "" {
		return
	}
	if mode != "missing-key" {
		fill := byte(1)
		if mode == "wrong-key" {
			fill = 2
		}
		codec, err := statecrypt.New(bytes.Repeat([]byte{fill}, statecrypt.KeyBytes))
		if err != nil {
			t.Fatal(err)
		}
		if err := statecrypt.Activate(codec); err != nil {
			t.Fatal(err)
		}
	}
	ctx := context.Background()
	const id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	const dest = "sensitive-destination.txt"
	const src = "source.txt"
	root := filepath.Join(state, "fixture-work")
	e := &Env{StateDir: state, Roots: []Root{{ID: "work", Path: root}}, Audit: commitAudit{}}
	if mode == "create" {
		if err := os.Mkdir(root, 0o700); err != nil {
			t.Fatal(err)
		}
		write := func(name, data string) string {
			t.Helper()
			path := filepath.Join(root, name)
			if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
				t.Fatal(err)
			}
			fi, err := os.Stat(path)
			if err != nil {
				t.Fatal(err)
			}
			return etag(fi)
		}
		raw, _ := json.Marshal(replaceRequest{
			ID: id, Root: "work", Path: "/" + src, ToRoot: "work", To: "/" + dest,
			IfMatch: write(src, "new"), ToIfMatch: write(dest, "old"),
		})
		if _, err := e.fsPasteReplace(ctx, raw); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(state, replacementReceipts, id+".json")
	data, err := os.ReadFile(path)
	if err != nil || !statecrypt.Protected(data) || bytes.Contains(data, []byte(dest)) {
		t.Fatalf("invalid protected receipt: %v", err)
	}
	raw, _ := json.Marshal(map[string]string{"id": id})
	result, err := e.fsPasteStatus(ctx, raw)
	if mode == "missing-key" || mode == "wrong-key" {
		if err == nil || wire.CodeOf(err) == wire.CodeNotFound {
			t.Fatalf("unreadable receipt incorrectly acknowledged or discarded: %v", err)
		}
	} else if err != nil || result.(replaceReceipt).Request.To != "/"+dest {
		t.Fatalf("protected receipt not recovered: %v %v", result, err)
	}
	after, readErr := os.ReadFile(path)
	if readErr != nil || !bytes.Equal(after, data) {
		t.Fatalf("query modified receipt: %v", readErr)
	}
}
