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
