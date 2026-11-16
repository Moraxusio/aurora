//go:build linux || windows

package ai

import (
	"aurora3/internal/wire"
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"
)

func uploadFixture(t *testing.T, e *Env, name string, b []byte) attachmentMeta {
	t.Helper()
	server, client := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	args, _ := json.Marshal(map[string]any{"name": name, "size": len(b)})
	done := make(chan error, 1)
	go func() { defer server.Close(); done <- (svc{e}).opAttachmentUpload(context.Background(), server, args) }()
	var response wire.Response
	if err := wire.ReadJSON(client, &response); err != nil || !response.OK {
		t.Fatalf("upload ready: %v", err)
	}
	for start := 0; start < len(b); start += 65536 {
		end := min(start+65536, len(b))
		if err := wire.WriteFrame(client, wire.TypeData, b[start:end]); err != nil {
			t.Fatal(err)
		}
	}
	if err := wire.WriteFrame(client, wire.TypeEnd, nil); err != nil {
		t.Fatal(err)
	}
	if err := wire.ReadJSON(client, &response); err != nil || !response.OK {
		t.Fatalf("upload finished: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	var meta attachmentMeta
	if err := json.Unmarshal(response.Result, &meta); err != nil {
		t.Fatal(err)
	}
	return meta
}
