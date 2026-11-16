//go:build linux || windows

package ai

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSlowSubscriberRequiresResync(t *testing.T) {
	e := &Env{}
	ch := e.subscribe()
	defer e.unsubscribe(ch)
	for i := 0; i < cap(ch); i++ {
		e.broadcast(StreamEvent{Type: "session.status", SessionID: "other", Status: "idle"})
	}
	e.broadcast(StreamEvent{Type: "text.delta", SessionID: "current", Delta: "latest"})
	if ev := <-ch; ev.Type != "sync.required" || ev.SessionID != "" {
		t.Fatalf("overflow must invalidate all sessions: %+v", ev)
	}
	if ev := <-ch; ev.Delta != "latest" {
		t.Fatalf("latest event lost: %+v", ev)
	}
}

func TestRevertWaitsForRunnerExit(t *testing.T) {
	e := &Env{Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	e.init()
	e.sessions["s"] = &Session{ID: "s", Root: "work", Workdir: "/", Messages: []Message{{ID: "m", Role: "user"}}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.running["s"] = &activeRun{cancel: cancel}
	if _, _, err := e.RevertSession(context.Background(), "s", "m", false); err == nil {
		t.Fatal("revert must not truncate history until the runner has exited")
	}
	if ctx.Err() == nil || len(e.sessions["s"].Messages) != 1 {
		t.Fatal("revert must request stop and retain the active history")
	}
}

func TestCompactionReservesSessionAndReportsPersistenceFailure(t *testing.T) {
	entered, release := make(chan struct{}, 1), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case entered <- struct{}{}:
		default:
		}
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"summary\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer server.Close()
	defer close(release)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	e.init()
	e.sessions["s"] = &Session{ID: "s", Root: "work", Workdir: "/", Agent: "build", Messages: []Message{
		{ID: "m", Role: "user", Parts: []Part{{Type: "text", Text: strings.Repeat("history ", 20000)}}},
	}}
	if err := persistFixture(e, e.sessions["s"]); err != nil {
		t.Fatal(err)
	}
	cfg := ProviderConfig{Protocol: "openai-chat", BaseURL: server.URL, Model: "fixture"}
	done := make(chan error, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _, err := e.CompactSession(ctx, "s", cfg); done <- err }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("compaction did not reach provider")
	}
	if _, err := e.StartRun(RunInput{SessionID: "s", Text: "new input", Provider: cfg}); err == nil {
		t.Error("run admitted during compaction")
		e.StopSession("s")
	}
	if _, _, err := e.RevertSession(context.Background(), "s", "m", false); err == nil {
		t.Error("revert admitted during compaction")
	}
	// Fail the checkpoint without destroying the previous file.
	target := filepath.Join(e.sessionsDir(), "s.json")
	if err := os.Rename(target, target+".backup"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	// Release just this response; the deferred close is also safe on failure.
	release <- struct{}{}
	select {
	case err := <-done:
		if err == nil {
			t.Error("compaction reported success despite failed checkpoint")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("compaction did not finish")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.sessions["s"].Messages) != 1 {
		t.Error("failed compaction changed in-memory history")
	}
}
