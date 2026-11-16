//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDeliveryWaitsForTaskBoundaryAndKeepsPerInputModel(t *testing.T) {
	type request struct {
		Model    string          `json:"model"`
		Messages json.RawMessage `json:"messages"`
		Tools    []any           `json:"tools"`
		Effort   string          `json:"reasoning_effort"`
	}
	requests := make(chan request, 8)
	replies := make(chan bool, 8)
	done := make(chan struct{})
	defer close(done)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var input request
		_ = json.NewDecoder(r.Body).Decode(&input)
		w.Header().Set("Content-Type", "text/event-stream")
		tool := false
		if len(input.Tools) > 0 {
			select {
			case requests <- input:
			case <-done:
				return
			}
			select {
			case tool = <-replies:
			case <-r.Context().Done():
				return
			case <-done:
				return
			}
		}
		if tool {
			fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"r1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n")
		} else {
			fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\n")
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer server.Close()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	env := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: dir}}}
	defer env.StopAll()
	events := env.subscribe()
	defer env.unsubscribe(events)
	provider := func(model string) ProviderConfig {
		return ProviderConfig{ID: model, Model: model, Protocol: "openai-chat", BaseURL: server.URL, APIKey: "never-save-this",
			ReasoningEffort: model + "-effort", Capabilities: map[string]bool{"grep": model != "queue-model-one"}}
	}
	sum, err := env.StartRun(RunInput{Root: "work", Workdir: "/", Agent: "plan", Text: "initial", Provider: provider("initial-model")})
	if err != nil {
		t.Fatal(err)
	}
	next := func() request {
		select {
		case input := <-requests:
			return input
		case <-time.After(5 * time.Second):
			t.Fatal("model request did not arrive")
			return request{}
		}
	}
	if got := next(); got.Model != "initial-model" {
		t.Fatal(got.Model)
	}
	for _, item := range []struct{ text, delivery, model string }{
		{"queued-one", "queue", "queue-model-one"},
		{"queued-two", "queue", "queue-model-two"},
		{"steering-now", "steer", "steer-model"},
	} {
		cfg := provider(item.model)
		_, err := env.StartRun(RunInput{SessionID: sum.ID, Agent: "plan", Text: item.text, Delivery: item.delivery, Provider: cfg})
		if err != nil {
			t.Fatal(err)
		}
		cfg.Capabilities["grep"] = !cfg.Capabilities["grep"]
	}
	sess, _, _, _ := env.GetSession(sum.ID)
	if sess.Model != "initial-model" || len(sess.Inbox) != 3 {
		t.Fatalf("admission altered active task: %#v", sess)
	}
	raw, _ := os.ReadFile(filepath.Join(env.StateDir, "ai", "sessions", sum.ID+".json"))
	log, _ := os.ReadFile(filepath.Join(env.StateDir, "ai", "sessions", sum.ID+".journal"))
	raw = append(raw, log...)
	if strings.Contains(string(raw), "never-save-this") {
		t.Fatal("queued credentials persisted")
	}
	if !strings.Contains(string(raw), "queued-one") {
		t.Fatal("pending input not persisted")
	}
	replies <- true
	got := next()
	if got.Model != "steer-model" || !strings.Contains(string(got.Messages), "steering-now") || strings.Contains(string(got.Messages), "queued-one") {
		t.Fatalf("steer/queue boundary broken: %s %s", got.Model, got.Messages)
	}
	replies <- true
	got = next()
	if got.Model != "steer-model" || strings.Contains(string(got.Messages), "queued-one") {
		t.Fatal("queue delivered while tools continued")
	}
	replies <- false
	got = next()
	if got.Model != "queue-model-one" || !strings.Contains(string(got.Messages), "queued-one") || strings.Contains(string(got.Messages), "queued-two") {
		t.Fatal("queued inputs were not delivered one at a time")
	}
	if strings.Contains(string(fixtureJSON(got.Tools)), `"name":"grep"`) || got.Effort != "queue-model-one-effort" {
		t.Fatal("first queued input lost its capabilities or custom effort")
	}
	replies <- false
	got = next()
	if got.Model != "queue-model-two" || !strings.Contains(string(got.Messages), "queued-two") {
		t.Fatal("second queue lost its model or input")
	}
	if !strings.Contains(string(fixtureJSON(got.Tools)), `"name":"grep"`) || got.Effort != "queue-model-two-effort" {
		t.Fatal("queued input inherited another input's options")
	}
	replies <- false
	timeout := time.After(5 * time.Second)
	for {
		select {
		case event := <-events:
			if event.Type == "session.status" && event.Status == "idle" {
				sess, running, _, _ := env.GetSession(sum.ID)
				if running || len(sess.Inbox) != 0 {
					t.Fatal("delivered queue not consumed")
				}
				return
			}
		case <-timeout:
			t.Fatal("runner did not become idle")
		}
	}
}

func TestStoppedInboxSurvivesReloadAndCanBeCancelled(t *testing.T) {
	env := &Env{StateDir: t.TempDir()}
	env.init()
	env.sessions["s"] = &Session{ID: "s", Inbox: []InboxItem{{ID: "q", Text: "retained", Delivery: "queue",
		Provider: ProviderConfig{APIKey: "not-on-disk"}, Runtime: &RuntimeInfo{Model: "m"}}}}
	if err := persistFixture(env, env.sessions["s"]); err != nil {
		t.Fatal(err)
	}
	reloaded := &Env{StateDir: env.StateDir}
	sess, _, _, err := reloaded.GetSession("s")
	if err != nil || len(sess.Inbox) != 1 || sess.Inbox[0].Provider.APIKey != "" || !sess.Inbox[0].Held {
		t.Fatal("pending input reload failed")
	}
	reloaded.running["s"] = &activeRun{provider: ProviderConfig{Model: "another-task"}}
	if _, err := (svc{reloaded}).opInbox(context.Background(), json.RawMessage(`{"session_id":"s","id":"q","action":"steer"}`)); err == nil {
		t.Fatal("retained input was silently admitted without fresh credentials")
	}
	if len(reloaded.running["s"].inbox) != 0 {
		t.Fatal("retained input contaminated the active task")
	}
	out, err := (svc{reloaded}).opInbox(context.Background(), json.RawMessage(`{"session_id":"s","id":"q","action":"cancel"}`))
	if err != nil || len(out.(map[string]any)["items"].([]InboxItem)) != 0 {
		t.Fatalf("cancel failed: %v", err)
	}
}

func TestAdmissionPersistenceFailureRetainsInputs(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(state, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	env := &Env{StateDir: state, Roots: []Root{{ID: "work", Path: dir}}}
	t.Cleanup(func() {
		// Startup recovery now latches this invalid-state-directory fault too.
		// Repair this test's path and release the process-wide write gate.
		if err := os.Remove(state); err != nil && !os.IsNotExist(err) {
			t.Error(err)
		}
		if err := env.fileTransactions().Recover(); err != nil {
			t.Error(err)
		}
	})
	provider := ProviderConfig{Model: "model", Protocol: "openai-chat", BaseURL: "http://127.0.0.1:1"}
	if _, err := env.StartRun(RunInput{Root: "work", Workdir: "/", Text: "first", Provider: provider}); err == nil {
		t.Fatal("unsaved first input was accepted")
	}
	if len(env.sessions) != 0 || len(env.running) != 0 {
		t.Fatal("failed admission left an orphan session")
	}
	env.sessions["s"] = &Session{ID: "s", Root: "work", Workdir: "/", Model: "original",
		Inbox: []InboxItem{{ID: "q", Text: "retained", Delivery: "queue"}}}
	if _, err := env.StartRun(RunInput{SessionID: "s", InboxID: "q", Provider: provider}); err == nil {
		t.Fatal("unsaved resume was accepted")
	}
	s := env.sessions["s"]
	if len(s.Inbox) != 1 || len(s.Messages) != 0 || s.Model != "original" || len(env.running) != 0 {
		t.Fatal("failed resume lost its input or changed the session")
	}
	env.running["s"] = &activeRun{provider: provider}
	if _, err := env.StartRun(RunInput{SessionID: "s", Text: "another", Delivery: "queue", Provider: provider}); err == nil {
		t.Fatal("unsaved queue item was accepted")
	}
	if len(s.Inbox) != 1 || len(env.running["s"].queued) != 0 {
		t.Fatal("failed queue admission changed the inbox")
	}
}

func TestSessionGrantCanBeRevokedAndExplicitDenyWinsInPlan(t *testing.T) {
	g := NewPermissionGate()
	g.allowedKeys["s\x00shell\x00npm *"] = true
	if len(g.SessionGrants("s", "", "", false)) != 1 {
		t.Fatal("grant missing")
	}
	g.SessionGrants("s", "shell", "npm *", true)
	if effect, _ := g.Evaluate("s", "build", "ask", "shell", "npm install"); effect != "ask" {
		t.Fatal("revoked grant still applies")
	}
	if effect, _ := g.EvaluateWithRules("s", "plan", "auto", "shell", "git push origin", []PermissionRule{{Action: "shell", Resource: "git push *", Effect: "deny"}}); effect != "deny" {
		t.Fatal("plan softened explicit deny")
	}
}
