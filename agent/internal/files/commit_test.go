//go:build linux || windows

package files

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/wire"
)

type commitAudit struct{}

func (commitAudit) Write(string, map[string]any) {}

func TestCheckedUploadRefusesNewCollisionAndStaleOverwrite(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "file.txt")
	e := &Env{Roots: []Root{{ID: "work", Path: root}}, UploadMaxBytes: 1 << 20, Audit: commitAudit{}}
	ctx := context.Background()
	base := `{"root":"work","path":"/file.txt","size":1`
	if err := os.WriteFile(target, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}
	stat, err := e.fsStat(ctx, json.RawMessage(base+"}"))
	if err != nil {
		t.Fatal(err)
	}
	stamp := stat.(entry).Etag
	if err := os.WriteFile(target, []byte("new bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range []string{base + `,"create":true}`, base + `,"if_match":"` + stamp + `"}`} {
		server, client := net.Pipe()
		server.SetDeadline(time.Now().Add(2 * time.Second))
		err := e.fsUpload(ctx, server, json.RawMessage(args))
		server.Close()
		client.Close()
		if wire.CodeOf(err) != wire.CodeConflict {
			t.Fatalf("expected rejection before upload admission: %v", err)
		}
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "new bytes" {
		t.Fatalf("lost current data: %q %v", data, err)
	}
}

func TestFileMutationsRejectStaleVersions(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "file.txt")
	e := &Env{Roots: []Root{{ID: "work", Path: root}}, Audit: commitAudit{}}
	ctx := context.Background()
	if err := os.WriteFile(target, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	stat, err := e.fsStat(ctx, json.RawMessage(`{"root":"work","path":"/file.txt"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("the replacement"), 0o644); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]string{
		"root": "work", "path": "/file.txt", "to": "/renamed.txt", "if_match": stat.(entry).Etag,
	})
	for _, op := range []func(context.Context, json.RawMessage) (any, error){e.fsRename, e.fsDelete, e.fsCopy} {
		if _, err := op(ctx, b); wire.CodeOf(err) != wire.CodeConflict {
			t.Fatalf("stale target unexpectedly modified: %v", err)
		}
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "the replacement" {
		t.Fatalf("lost current data: %q %v", data, err)
	}
}

func TestUploadRevalidatesAtCommitWithoutBlockingEditorSave(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "file.txt")
	if err := os.WriteFile(target, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	e := &Env{Roots: []Root{{ID: "work", Path: root}}, UploadMaxBytes: 1 << 20, Audit: commitAudit{}}
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	client.SetDeadline(time.Now().Add(10 * time.Second))
	done := make(chan error, 1)
	go func() {
		done <- e.fsUpload(context.Background(), server, json.RawMessage(`{"root":"work","path":"/file.txt","size":6}`))
	}()
	typ, _, err := wire.ReadFrame(client)
	if err != nil || typ != wire.TypeJSON {
		t.Fatalf("upload admission: %v %v", typ, err)
	}
	// Upload is now waiting for the network. A normal editor save must finish.
	saved := make(chan error, 1)
	go func() {
		_, err := e.fsWrite(context.Background(), json.RawMessage(`{"root":"work","path":"/file.txt","content":"editor changed"}`))
		saved <- err
	}()
	select {
	case err := <-saved:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("upload held the commit lock while waiting for network input")
	}
	if err := wire.WriteFrame(client, wire.TypeData, []byte("upload")); err != nil {
		t.Fatal(err)
	}
	if err := wire.WriteFrame(client, wire.TypeEnd, nil); err != nil {
		t.Fatal(err)
	}
	if err := <-done; wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("upload replaced an intervening editor save: %v", err)
	}
	data, _ := os.ReadFile(target)
	if string(data) != "editor changed" {
		t.Fatalf("lost editor data: %q", data)
	}
	matches, _ := filepath.Glob(filepath.Join(root, partPrefix+"*"))
	if len(matches) != 0 {
		t.Fatalf("staged upload leaked: %v", matches)
	}
}
