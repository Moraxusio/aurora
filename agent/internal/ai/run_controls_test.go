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
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func controlsReply(w http.ResponseWriter, delta map[string]any, finish string) {
	w.Header().Set("Content-Type", "text/event-stream")
	fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n",
		fixtureJSON(map[string]any{"choices": []any{map[string]any{"delta": delta, "finish_reason": finish}}}))
}

func controlsCall(i int, name string, arguments any) any {
	return map[string]any{"index": i, "id": fmt.Sprintf("call-%d", i), "type": "function",
		"function": map[string]any{"name": name, "arguments": string(fixtureJSON(arguments))}}
}

func controlsIdle(t *testing.T, events <-chan StreamEvent, id string) {
	t.Helper()
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		select {
		case ev := <-events:
			if ev.SessionID == id && ev.Type == "session.status" && ev.Status == "idle" {
				return
			}
		case <-timer.C:
			t.Fatal("task did not become idle")
		}
	}
}

func TestControlsParallelChildrenCheckpointAndTotalLimit(t *testing.T) {
	entered := make(chan chan struct{}, 4)
	var active, peak, children atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages json.RawMessage
			Tools    json.RawMessage
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.Contains(string(body.Messages), "You are a subagent spawned") {
			children.Add(1)
			n := active.Add(1)
			defer active.Add(-1)
			for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
			}
			if strings.Contains(string(body.Tools), `"name":"subagent"`) {
				t.Error("child advertised delegation")
			}
			release := make(chan struct{})
			entered <- release
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
			controlsReply(w, map[string]any{"content": "child completed"}, "stop")
		} else if !strings.Contains(string(body.Messages), `"tool_calls"`) {
			calls := []any{}
			for i := 0; i < 4; i++ {
				calls = append(calls, controlsCall(i, "subagent", map[string]string{"agent": "explore", "description": fmt.Sprintf("child %d", i), "prompt": fmt.Sprintf("inspect %d", i)}))
			}
			controlsReply(w, map[string]any{"tool_calls": calls}, "tool_calls")
		} else {
			controlsReply(w, map[string]any{"content": "all finished"}, "stop")
		}
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"snapshots":false,"subagents":{"maxParallel":2,"maxTotal":2}}`)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	defer e.StopAll()
	ev := e.subscribe()
	defer e.unsubscribe(ev)
	sum, err := e.StartRun(RunInput{Root: "work", Workdir: "/", Text: "delegate", PermissionMode: "auto",
		Provider: ProviderConfig{Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	next := func() chan struct{} {
		select {
		case ch := <-entered:
			return ch
		case <-time.After(5 * time.Second):
			t.Fatal("children did not overlap")
			return nil
		}
	}
	first, second := next(), next()
	sess, _, _, _ := e.GetSession(sum.ID)
	if sess.Budget.ChildrenActive != 2 || peak.Load() != 2 {
		t.Fatal(sess.Budget, peak.Load())
	}
	close(first)
	// A completed child is persisted while the other remains in flight.
	checkpointed := false
	timer := time.NewTimer(5 * time.Second)
	for !checkpointed {
		select {
		case event := <-ev:
			if event.Type == "tool.done" && event.SessionID == sum.ID {
				s, _, _, _ := e.GetSession(sum.ID)
				for _, m := range s.Messages {
					for _, p := range m.Parts {
						if p.Type == "tool-result" && strings.Contains(p.Output, "child completed") {
							checkpointed = true
						}
					}
				}
			}
		case <-timer.C:
			close(second)
			t.Fatal("completed child was not checkpointed")
		}
	}
	timer.Stop()
	close(second)
	controlsIdle(t, ev, sum.ID)
	sess, _, _, _ = e.GetSession(sum.ID)
	if children.Load() != 2 || sess.Budget.ChildrenActive != 0 || sess.Budget.ChildrenStarted != 2 {
		t.Fatal(children.Load(), sess.Budget)
	}
	found := false
	for _, m := range sess.Messages {
		for _, p := range m.Parts {
			if p.IsError && strings.Contains(p.Output, "已达到 2") {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("total limit did not return a tool result")
	}
}

func TestControlsQueuedMessagesOwnBudgetsAndAdmittedPolicy(t *testing.T) {
	requests := make(chan string, 4)
	replies := make(chan struct{}, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Model string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		requests <- body.Model
		select {
		case <-replies:
		case <-r.Context().Done():
			return
		}
		controlsReply(w, map[string]any{"content": "done"}, "stop")
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"budget":{"steps":1,"seconds":1,"tokens":0}}`)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	defer e.StopAll()
	events := e.subscribe()
	defer e.unsubscribe(events)
	input := RunInput{Root: "work", Workdir: "/", Text: "first", Provider: ProviderConfig{Model: "first", Protocol: "openai-chat", BaseURL: server.URL}}
	sum, err := e.StartRun(input)
	if err != nil {
		t.Fatal(err)
	}
	next := func(want string) {
		select {
		case got := <-requests:
			if got != want {
				t.Fatal(got, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("missing request %s", want)
		}
	}
	next("first")
	first, _, _, _ := e.GetSession(sum.ID)
	input.SessionID = sum.ID
	input.Text, input.Provider.Model, input.Delivery = "second", "second", "queue"
	input.Options = &RunOptions{BudgetMode: "custom", Budget: &RunBudget{Steps: 1, Seconds: 3}}
	if _, err = e.StartRun(input); err != nil {
		t.Fatal(err)
	}
	input.Delivery = "steer"
	if _, err = e.StartRun(input); err == nil {
		t.Fatal("steering accepted independent budget")
	}
	// Project edits after admission must not change the queued message.
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"budget":{"tokens":1}}`)
	replies <- struct{}{}
	next("second")
	second, _, _, _ := e.GetSession(sum.ID)
	if second.Budget.ID == first.Budget.ID || second.Budget.Steps != 1 || second.Budget.Source != "message" ||
		second.Budget.Limits.Seconds != 3 || second.Budget.Limits.Tokens != 0 {
		t.Fatal(first.Budget, second.Budget)
	}
	// Cross the original turn's deadline; a queue must use the base cancel
	// context and its own timer rather than inheriting an expired deadline.
	time.Sleep(1100 * time.Millisecond)
	replies <- struct{}{}
	controlsIdle(t, events, sum.ID)
	second, _, _, _ = e.GetSession(sum.ID)
	last := second.Messages[len(second.Messages)-1]
	if last.Error != "" || last.Finish != "stop" {
		t.Fatal(last)
	}
}

func TestControlsResumedChildCannotDelegateOrLoseReadOnly(t *testing.T) {
	var declared atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages json.RawMessage
			Tools    json.RawMessage
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.Contains(string(body.Tools), `"name":"subagent"`) || strings.Contains(string(body.Tools), `"name":"write"`) {
			declared.Store(true)
		}
		if !strings.Contains(string(body.Messages), `"tool_calls"`) {
			controlsReply(w, map[string]any{"tool_calls": []any{controlsCall(0, "subagent", map[string]string{"agent": "general", "description": "nested", "prompt": "write"})}}, "tool_calls")
		} else {
			controlsReply(w, map[string]any{"content": "done"}, "stop")
		}
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false}`)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	e.init()
	e.sessions["child"] = &Session{ID: "child", ParentID: "parent", Root: "work", Workdir: "/", Agent: "explore"}
	if err := persistFixture(e, e.sessions["child"]); err != nil {
		t.Fatal(err)
	}
	events := e.subscribe()
	defer e.unsubscribe(events)
	_, err := e.StartRun(RunInput{SessionID: "child", Agent: "build", PermissionMode: "auto", Text: "continue",
		Provider: ProviderConfig{Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	controlsIdle(t, events, "child")
	s, _, _, _ := e.GetSession("child")
	if declared.Load() || s.Agent != "explore" || len(e.ListSessions(true)) != 1 {
		t.Fatal("resumed child escaped its boundary", s.Agent)
	}
}

func TestControlsDisabledBudgetStillMetersAndCancelledSlotsDoNotStart(t *testing.T) {
	cfg := defaultExtensionConfig()
	cfg.Budget = RunBudget{Steps: 1, Tokens: 1, Seconds: 1, OutputBytes: 1}
	off := false
	cfg.BudgetEnabled = &off
	m := newRunMeter(cfg)
	for i := 0; i < 3; i++ {
		finish, err := m.reserve(&LLMRequest{MaxTokens: 20})
		if err != nil {
			t.Fatal(err)
		}
		finish(&LLMResponse{Usage: Usage{InputTokens: 100, OutputTokens: 10}}, false)
	}
	if m.snapshot().Enabled || m.snapshot().Tokens != 330 || !m.deadline.IsZero() {
		t.Fatal(m.snapshot())
	}
	release, err := m.acquireChild(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = m.acquireChild(ctx); err == nil {
		t.Fatal("cancelled child acquired a slot")
	}
	release()
	if m.snapshot().ChildrenActive != 0 || m.snapshot().ChildrenStarted != 1 {
		t.Fatal(m.snapshot())
	}
}

func TestControlsToolLimitAndRepeatApproval(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if calls.Add(1) <= 2 {
			controlsReply(w, map[string]any{"tool_calls": []any{
				controlsCall(0, "read", map[string]string{"path": "a.txt"}),
				controlsCall(1, "write", map[string]string{"path": "must-not-exist", "content": "bad"}),
			}}, "tool_calls")
		} else {
			controlsReply(w, map[string]any{"content": "finished"}, "stop")
		}
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"snapshots":false,"tools":{"maxCallsPerStep":1,"repeatLimit":2}}`)
	if err := os.WriteFile(filepath.Join(work, "a.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	defer e.StopAll()
	events := e.subscribe()
	defer e.unsubscribe(events)
	sum, err := e.StartRun(RunInput{Root: "work", Text: "inspect", PermissionMode: "auto",
		Provider: ProviderConfig{Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	approved := false
	done := false
	for !done {
		select {
		case ev := <-events:
			if ev.Type == "permission.ask" {
				if ev.Permission.Action != "doom_loop" {
					t.Fatal(ev.Permission)
				}
				approved = e.perms.Resolve(ev.Permission.ID, PermissionDecision{Allow: true})
			}
			done = ev.SessionID == sum.ID && ev.Type == "session.status" && ev.Status == "idle"
		case <-timer.C:
			t.Fatal("repeat approval workflow timed out")
		}
	}
	if !approved {
		t.Fatal("repeat policy did not ask")
	}
	if _, err := os.Stat(filepath.Join(work, "must-not-exist")); !os.IsNotExist(err) {
		t.Fatal("tool count limit allowed write", err)
	}
}

func TestControlsShellUsesConfiguredTimeout(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	e.init()
	cfg := defaultExtensionConfig()
	cfg.Tools = &ToolOptions{MaxCallsPerStep: 64, RepeatLimit: 3, ShellDefaultSeconds: 1, ShellMaxSeconds: 2}
	work := t.TempDir()
	cmd := "sleep 5"
	if runtime.GOOS == "windows" {
		cmd = "Start-Sleep -Seconds 5"
	}
	tc := toolContext{env: e, session: &Session{ID: "shell", Agent: "build", PermissionMode: "auto"},
		rootPath: work, absWorkdir: work, extensions: &extensionRuntime{config: cfg}}
	start := time.Now()
	result := executeTool(context.Background(), tc, "shell", fixtureJSON(map[string]string{"command": cmd}))
	if !result.IsError || result.Metadata["timeout"] != true || time.Since(start) > 4*time.Second {
		t.Fatal(result, time.Since(start))
	}
}

func TestControlsStoppingParentCancelsParallelChildren(t *testing.T) {
	entered := make(chan struct{}, 2)
	stopped := make(chan struct{}, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Messages json.RawMessage }
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.Contains(string(body.Messages), "You are a subagent spawned") {
			entered <- struct{}{}
			<-r.Context().Done()
			stopped <- struct{}{}
			return
		}
		controlsReply(w, map[string]any{"tool_calls": []any{
			controlsCall(0, "subagent", map[string]string{"agent": "explore", "description": "one", "prompt": "one"}),
			controlsCall(1, "subagent", map[string]string{"agent": "explore", "description": "two", "prompt": "two"}),
		}}, "tool_calls")
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"snapshots":false,"subagents":{"maxParallel":2}}`)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	defer e.StopAll()
	events := e.subscribe()
	defer e.unsubscribe(events)
	sum, err := e.StartRun(RunInput{Root: "work", Text: "parallel", PermissionMode: "auto",
		Provider: ProviderConfig{Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("child did not start")
		}
	}
	e.StopSession(sum.ID)
	controlsIdle(t, events, sum.ID)
	for i := 0; i < 2; i++ {
		select {
		case <-stopped:
		case <-time.After(5 * time.Second):
			t.Fatal("child request was not cancelled")
		}
	}
	for _, s := range e.ListSessions(true) {
		if s.Running {
			t.Fatal("child survived parent stop", s.ID)
		}
	}
	s, _, _, _ := e.GetSession(sum.ID)
	if s.Budget.ChildrenActive != 0 {
		t.Fatal(s.Budget)
	}
}

func TestControlsStoppingOneChildPreservesSiblingAndResultReference(t *testing.T) {
	entered := make(chan struct{}, 2)
	cancelled := make(chan struct{}, 2)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Messages json.RawMessage }
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.Contains(string(body.Messages), "You are a subagent spawned") {
			entered <- struct{}{}
			select {
			case <-r.Context().Done():
				cancelled <- struct{}{}
				return
			case <-release:
				controlsReply(w, map[string]any{"content": "sibling completed"}, "stop")
			}
		} else if strings.Contains(string(body.Messages), `"tool_calls"`) {
			controlsReply(w, map[string]any{"content": "parent completed"}, "stop")
		} else {
			controlsReply(w, map[string]any{"tool_calls": []any{
				controlsCall(0, "subagent", map[string]string{"agent": "explore", "description": "one", "prompt": "one"}),
				controlsCall(1, "subagent", map[string]string{"agent": "explore", "description": "two", "prompt": "two"}),
			}}, "tool_calls")
		}
	}))
	defer server.Close()
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"snapshots":false,"subagents":{"maxParallel":2}}`)
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	defer e.StopAll()
	events := e.subscribe()
	defer e.unsubscribe(events)
	sum, err := e.StartRun(RunInput{Root: "work", Text: "parallel", PermissionMode: "auto",
		Provider: ProviderConfig{Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("child did not start")
		}
	}
	var childID string
	for _, s := range e.ListSessions(true) {
		if s.ParentID == sum.ID {
			childID = s.ID
			break
		}
	}
	if childID == "" || !e.StopSession(childID) {
		t.Fatal("child stop was not admitted")
	}
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("child request survived stop")
	}
	controlsIdle(t, events, childID)
	alive := 0
	for _, s := range e.ListSessions(true) {
		if s.Running {
			alive++
		}
	}
	if alive != 2 {
		t.Fatalf("parent and sibling should remain active, got %d", alive)
	}
	close(release)
	controlsIdle(t, events, sum.ID)
	parent, _, _, _ := e.GetSession(sum.ID)
	stoppedResult, siblingResult := false, false
	for _, m := range parent.Messages {
		for _, p := range m.Parts {
			if p.Type != "tool-result" || p.ToolName != "subagent" {
				continue
			}
			if p.Metadata["child_session_id"] == childID {
				stoppedResult = p.IsError && p.Metadata["cancelled"] == true
			} else {
				siblingResult = !p.IsError && strings.Contains(p.Output, "sibling completed")
			}
		}
	}
	if !stoppedResult || !siblingResult || parent.Budget.ChildrenActive != 0 {
		t.Fatal("terminal child results lost cancellation or reference", stoppedResult, siblingResult, parent.Budget)
	}
}
