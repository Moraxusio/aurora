//go:build linux

package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
	"github.com/klauspost/compress/zstd"
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
		end := start + 65536
		if end > len(b) {
			end = len(b)
		}
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

func TestAttachmentChunkTransferAndCompactWire(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	// >1 MiB, intentionally a transport fixture, not a PDF rendering fixture.
	b := append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte("fixture data "), 100000)...)
	m := uploadFixture(t, e, `C:\local\private\document.pdf`, b)
	if m.Name != "document.pdf" || m.Size != int64(len(b)) || m.Mime != "application/pdf" {
		t.Fatalf("metadata: %+v", m)
	}
	parts := e.userParts("read this", []ContextAttachment{{AttachmentID: m.ID}})
	stored := Message{Role: "user", Parts: parts}
	raw, _ := json.Marshal(stored)
	if len(raw) > 2048 || bytes.Contains(raw, []byte("fixture data")) || bytes.Contains(raw, []byte(`C:\local`)) {
		t.Fatal("binary or local path leaked into chat wire")
	}
	var buf bytes.Buffer
	if err := wire.WriteJSON(&buf, stored); err != nil {
		t.Fatalf("message exceeded wire limit: %v", err)
	}
	info, err := os.Stat(filepath.Join(e.attachmentDir(), m.ID+".bin"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("attachment permissions")
	}
	materialized, err := materializeAttachments([]Message{stored}, e.loadAttachment)
	if err != nil || !strings.HasPrefix(materialized[0].Parts[1].DataURL, "data:application/pdf;base64,") {
		t.Fatalf("materialize: %v", err)
	}
	if stored.Parts[1].DataURL != "" {
		t.Fatal("materialize mutated stored session")
	}
	server, client := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	args, _ := json.Marshal(map[string]string{"id": m.ID})
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		done <- (svc{e}).opAttachmentDownload(context.Background(), server, args)
	}()
	var response wire.Response
	if err := wire.ReadJSON(client, &response); err != nil {
		t.Fatal(err)
	}
	var got bytes.Buffer
	for {
		typ, payload, err := wire.ReadFrame(client)
		if err != nil {
			t.Fatal(err)
		}
		if typ == wire.TypeEnd {
			break
		}
		if typ != wire.TypeData {
			t.Fatal("bad download frame")
		}
		got.Write(payload)
	}
	if err := <-done; err != nil || !bytes.Equal(got.Bytes(), b) {
		t.Fatal("attachment bytes changed")
	}
	if err := os.WriteFile(filepath.Join(e.attachmentDir(), m.ID+".bin"), bytes.Repeat([]byte{1}, len(b)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := e.loadAttachment(parts[1]); err == nil {
		t.Fatal("changed attachment accepted")
	}
	if _, err := e.attachmentMeta("../../private"); err == nil {
		t.Fatal("traversal accepted")
	}
}

func TestAttachmentIncompleteUploadDoesNotCommit(t *testing.T) {
	for _, mode := range []string{"disconnect", "wrong-size", "unsupported", "oversized", "bad-end"} {
		t.Run(mode, func(t *testing.T) {
			e := &Env{StateDir: t.TempDir()}
			server, client := net.Pipe()
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(5 * time.Second))
			done := make(chan error, 1)
			go func() {
				defer server.Close()
				done <- (svc{e}).opAttachmentUpload(context.Background(), server, json.RawMessage(`{"name":"fixture.bin","size":4}`))
			}()
			var response wire.Response
			if err := wire.ReadJSON(client, &response); err != nil {
				t.Fatal(err)
			}
			payload := []byte("ab")
			if mode == "unsupported" {
				payload = []byte{0, 0, 0, 0}
			}
			if mode == "oversized" {
				payload = []byte("abcde")
			}
			if mode == "bad-end" {
				payload = []byte("abcd")
			}
			_ = wire.WriteFrame(client, wire.TypeData, payload)
			if mode == "disconnect" {
				client.Close()
			} else if mode == "bad-end" {
				_ = wire.WriteFrame(client, wire.TypeEnd, []byte{1})
			} else if mode != "oversized" {
				_ = wire.WriteFrame(client, wire.TypeEnd, nil)
			}
			if err := <-done; err == nil {
				t.Fatal("invalid upload accepted")
			}
			entries, _ := os.ReadDir(e.attachmentDir())
			if len(entries) != 0 {
				t.Fatal("partial upload left files")
			}
		})
	}
}

func TestMediaLoweringForAllProtocols(t *testing.T) {
	png, _ := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJZkAAAAASUVORK5CYII=")
	for _, protocol := range []string{"openai-chat", "openai-responses", "anthropic-messages"} {
		t.Run(protocol, func(t *testing.T) {
			e := &Env{StateDir: t.TempDir()}
			image := uploadFixture(t, e, "image.png", png)
			text := uploadFixture(t, e, "code.dart", []byte("void main() { /* fixture */ }"))
			pdf := uploadFixture(t, e, "document.pdf", []byte("%PDF-1.7\nfixture"))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				b, _ := io.ReadAll(r.Body)
				if !bytes.Contains(b, []byte("void main()")) || !bytes.Contains(b, []byte(base64.StdEncoding.EncodeToString(png))) {
					t.Error("media/text missing from provider request")
				}
				var value map[string]any
				if json.Unmarshal(b, &value) != nil {
					t.Error("invalid provider JSON")
				}
				switch protocol {
				case "openai-chat":
					if !bytes.Contains(b, []byte(`"type":"image_url"`)) || !bytes.Contains(b, []byte(`"file_data"`)) {
						t.Error("chat media schema")
					}
				case "openai-responses":
					if !bytes.Contains(b, []byte(`"type":"input_image"`)) || !bytes.Contains(b, []byte(`"type":"input_file"`)) {
						t.Error("responses media schema")
					}
				case "anthropic-messages":
					if !bytes.Contains(b, []byte(`"media_type":"image/png"`)) || !bytes.Contains(b, []byte(`"type":"document"`)) {
						t.Error("anthropic media schema")
					}
				}
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: [DONE]\n\n")
			}))
			defer server.Close()
			parts := e.userParts("analyze", []ContextAttachment{{AttachmentID: image.ID}, {AttachmentID: text.ID}, {AttachmentID: pdf.ID}})
			_, err := StreamLLM(context.Background(), LLMRequest{Provider: ProviderConfig{Protocol: protocol, BaseURL: server.URL, Model: "fixture"}, Messages: []Message{{Role: "user", Parts: parts}}, LoadAttachment: e.loadAttachment}, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			if EstimateMessagesTokens([]Message{{Parts: parts}}) < 1600 {
				t.Fatal("media absent from estimated context")
			}
		})
	}
}

func TestLargeSubscriptionMediaUsesZstd(t *testing.T) {
	oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Encoding") != "zstd" {
			t.Error("large subscription body not compressed")
		}
		decoder, err := zstd.NewReader(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		defer decoder.Close()
		b, err := io.ReadAll(decoder)
		if err != nil || !bytes.Contains(b, []byte(`"type":"input_file"`)) {
			t.Error("large attachment request damaged")
		}
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{}}\n\n")
	})
	p := Part{Type: "file", Mime: "application/pdf", Filename: "large.pdf", AttachmentID: "fixture"}
	_, err := StreamLLM(context.Background(), LLMRequest{Provider: ProviderConfig{AuthMode: ChatGPTAuthMode, APIKey: "access-fixture", Model: "gpt-6.1-sol"}, Messages: []Message{{Role: "user", Parts: []Part{p}}}, LoadAttachment: func(Part) ([]byte, error) {
		return append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte("fixture"), 100000)...), nil
	}}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
}

func TestDeletingSessionOnlyRemovesUnsharedAttachmentData(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	e.init()
	m := uploadFixture(t, e, "fixture.txt", []byte("private fixture data"))
	for _, id := range []string{"a", "b"} {
		e.sessions[id] = &Session{ID: id, Messages: []Message{{Role: "user", Parts: e.userParts("", []ContextAttachment{{AttachmentID: m.ID}})}}}
	}
	path := filepath.Join(e.attachmentDir(), m.ID+".bin")
	if err := e.DeleteSession("a"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("shared attachment deleted")
	}
	e.running["pending"] = &activeRun{inbox: []InboxItem{{Attachments: []ContextAttachment{{AttachmentID: m.ID}}}}}
	if err := e.DeleteSession("b"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("attachment referenced by active steering inbox deleted")
	}
	e.mu.Lock()
	delete(e.running, "pending")
	e.removeUnusedAttachmentsLocked(map[string]bool{m.ID: true})
	e.mu.Unlock()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("deleted session attachment was retained")
	}
}

func TestAttachmentLimitsAndStoreQuota(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	m := uploadFixture(t, e, "fixture.pdf", append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte("x"), maxAttachmentBytes-9)...))
	a := ContextAttachment{AttachmentID: m.ID}
	if err := e.validateAttachments([]ContextAttachment{a, a}); err != nil {
		t.Fatal(err)
	}
	if err := e.validateAttachments([]ContextAttachment{a, a, a}); err == nil {
		t.Fatal("more than 20 MiB accepted")
	}
	if err := e.validateAttachments(make([]ContextAttachment, 9)); err == nil {
		t.Fatal("more than 8 attachments accepted")
	}
	if _, err := attachmentMime(bytes.Repeat([]byte("x"), (256<<10)+1)); err == nil {
		t.Fatal("oversized text accepted")
	}
	// Sparse quota fixture: no real user files and no 512 MiB allocation.
	f, err := os.Create(filepath.Join(e.attachmentDir(), "quota-fixture.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(512 << 20); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	if err := (svc{e}).opAttachmentUpload(context.Background(), server, json.RawMessage(`{"name":"new.txt","size":1}`)); err == nil {
		t.Fatal("full attachment store accepted upload")
	}
}
