//go:build linux || windows

package ai

import (
	"context"
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
)

func TestProposalUsesUnsavedSnapshotsAcrossProtocolsWithoutWriting(t *testing.T) {
	for _, protocol := range []string{"openai-chat", "openai-responses", "anthropic-messages"} {
		t.Run(protocol, func(t *testing.T) {
			root := t.TempDir()
			os.WriteFile(filepath.Join(root, "file.go"), []byte("disk original"), 0600)
			answer := `{"changes":[{"path":"/file.go","old":"unsaved","new":"reviewed"}]}`
			requests := make(chan string, 1)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				json.NewDecoder(r.Body).Decode(&body)
				data, _ := json.Marshal(body)
				requests <- string(data)
				if r.Header.Get("User-Agent") != OpenCodeUserAgent {
					t.Error("compatibility user agent changed")
				}
				if tools, ok := body["tools"].([]any); ok && len(tools) > 0 {
					t.Error("proposal exposed file tools")
				}
				w.Header().Set("Content-Type", "text/event-stream")
				switch protocol {
				case "openai-chat":
					fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"content": answer}, "finish_reason": "stop"}}}))+"\n\ndata: [DONE]\n\n")
				case "openai-responses":
					fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "response.output_text.delta", "delta": answer}))+"\n\n")
					fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
				default:
					fmt.Fprint(w, "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12}}}\n\n")
					fmt.Fprint(w, "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n")
					fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": answer}}))+"\n\n")
					fmt.Fprint(w, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n")
				}
			}))
			defer upstream.Close()
			e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
			in := proposalRequest{Root: "work", Workdir: "/", Mode: "edit", Instruction: "improve",
				Documents: []proposalDocument{{Path: "/file.go", Version: 3, ETag: "v1", Text: "unsaved buffer"}},
				Provider:  ProviderConfig{Protocol: protocol, Model: "fixture", BaseURL: upstream.URL, APIKey: "secret"}}
			server, client := net.Pipe()
			defer client.Close()
			client.SetDeadline(time.Now().Add(5 * time.Second))
			done := make(chan error, 1)
			go func() {
				err := (svc{e}).opPropose(context.Background(), server, fixtureJSON(in))
				if err != nil {
					wire.WriteJSON(server, wire.ErrResponse(err))
				}
				server.Close()
				done <- err
			}()
			var ready, result wire.Response
			if err := wire.ReadJSON(client, &ready); err != nil || !ready.OK {
				t.Fatal(ready, err)
			}
			if err := wire.ReadJSON(client, &result); err != nil || !result.OK {
				t.Fatal(result, err)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			payload := <-requests
			if !strings.Contains(payload, "unsaved buffer") || strings.Contains(payload, "disk original") || strings.Contains(payload, "secret") {
				t.Fatal(payload)
			}
			if data, _ := os.ReadFile(filepath.Join(root, "file.go")); string(data) != "disk original" {
				t.Fatal("proposal wrote files")
			}
			if len(e.proposalCancels) != 0 {
				t.Fatal("proposal leaked budget")
			}
		})
	}
}

func TestProposalRejectsAmbiguousOverlappingAndUnknownTargets(t *testing.T) {
	in := proposalRequest{Mode: "edit", Documents: []proposalDocument{{Path: "/a", Text: "abc abc unique"}}}
	for _, result := range []proposalResult{
		{Changes: []proposalChange{{Path: "/a", Old: "abc", New: "x"}}},
		{Changes: []proposalChange{{Path: "/outside", Old: "unique", New: "x"}}},
		{Changes: []proposalChange{{Path: "/a", Old: "unique", New: "x"}, {Path: "/a", Old: "nique", New: "y"}}},
	} {
		if validateProposal(in, result) == nil {
			t.Fatal("invalid proposal accepted")
		}
	}
}

func TestProposalResetCancelsUpstreamAndReleasesBudget(t *testing.T) {
	started, cancelled := make(chan struct{}), make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
		close(cancelled)
	}))
	defer upstream.Close()
	e := &Env{Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	in := proposalRequest{Root: "work", Workdir: "/", Mode: "complete", Documents: []proposalDocument{{Path: "/a", Text: "x"}},
		Provider: ProviderConfig{Protocol: "openai-chat", Model: "fixture", BaseURL: upstream.URL}}
	server, client := net.Pipe()
	done := make(chan struct{})
	go func() { defer close(done); (svc{e}).opPropose(context.Background(), server, fixtureJSON(in)) }()
	var ready wire.Response
	if err := wire.ReadJSON(client, &ready); err != nil {
		t.Fatal(err)
	}
	<-started
	client.Close()
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("upstream not cancelled")
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("stream leaked")
	}
	if len(e.proposalCancels) != 0 {
		t.Fatal("budget leaked")
	}
}

func TestStripJSONCodeFence(t *testing.T) {
	fenced := "```json\n{\"changes\":[{\"path\":\"/a\",\"old\":\"x\",\"new\":\"y\"}]}\n```"
	if got := stripJSONCodeFence(fenced); !strings.HasPrefix(got, `{"changes":`) {
		t.Fatalf("failed to strip json fence: %q", got)
	}
	plain := `{"completion":"ok"}`
	if got := stripJSONCodeFence(plain); got != plain {
		t.Fatalf("plain json modified: %q", got)
	}
}
