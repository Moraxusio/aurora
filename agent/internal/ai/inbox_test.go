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

func TestLivePermissionCannotBeReplacedByPendingInput(t *testing.T) {
	for _, delivery := range []string{"queue", "steer"} {
		t.Run(delivery, func(t *testing.T) {
			arrived := make(chan struct{}, 4)
			release := make(chan struct{}, 4)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				arrived <- struct{}{}
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic reply\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
			}))
			defer server.Close()
			env := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
			defer env.StopAll()
			events := env.subscribe()
			defer env.unsubscribe(events)
			no := false
			in := RunInput{
				Root: "work", Workdir: "/", Agent: "build", PermissionMode: "full_access", Text: "first",
				Provider: ProviderConfig{Model: "first-model", Protocol: "openai-chat", BaseURL: server.URL},
				Options:  &RunOptions{AutoTitle: &no},
			}
			next := func() {
				t.Helper()
				select {
				case <-arrived:
				case <-time.After(5 * time.Second):
					t.Fatal("model fixture was not reached")
				}
			}
			sum, err := env.StartRun(in)
			if err != nil {
				t.Fatal(err)
			}
			next()
			in.SessionID, in.Text, in.Delivery = sum.ID, "pending", delivery
			in.Provider.Model = "pending-model"
			in.SubagentPermissionMode = "full_access"
			in.SubagentPermissionRules = []PermissionRule{{Action: "write", Resource: "*", Effect: "allow"}}
			in.Options = nil
			if _, err := env.StartRun(in); err != nil {
				t.Fatal(err)
			}
			ask := "ask"
			rules := []PermissionRule{{Action: "write", Resource: "notes.md", Effect: "deny"}}
			if _, err := env.UpdateSessionPermission(sum.ID, &ask, &rules); err != nil {
				t.Fatal(err)
			}
			before, _, _, err := env.GetSession(sum.ID)
			if err != nil || len(before.Inbox) != 1 || before.Inbox[0].PermissionMode != "ask" {
				t.Fatalf("pending input did not show the current policy: %+v %v", before.Inbox, err)
			}
			release <- struct{}{}
			next()
			after, _, _, err := env.GetSession(sum.ID)
			if err != nil || after.PermissionMode != "ask" || len(after.PermissionRules) != 1 ||
				after.PermissionRules[0].Effect != "deny" || after.Model != "pending-model" {
				t.Fatalf("delivery changed authorization or lost its model: %v %+v", err, after)
			}
			env.mu.Lock()
			run := env.running[sum.ID]
			staleChildPolicy := run.subagentPermMode != "" || len(run.subagentPermRules) != 0
			env.mu.Unlock()
			if staleChildPolicy {
				t.Fatal("delivery replaced the active child policy")
			}
			release <- struct{}{}
			timeout := time.NewTimer(5 * time.Second)
			defer timeout.Stop()
			for {
				select {
				case event := <-events:
					if event.SessionID == sum.ID && event.Type == "session.status" && event.Status == "idle" {
						return
					}
				case <-timeout.C:
					t.Fatal("pending input did not finish")
				}
			}
		})
	}
}

func TestLiveParentPolicyAppliesToManagedChildAndPendingApproval(t *testing.T) {
	root := t.TempDir()
	env := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	events := env.subscribe()
	defer env.unsubscribe(events)
	parent := &Session{ID: "parent", Agent: "orchestrator", PermissionMode: "full_access"}
	child := &Session{ID: "child", ParentID: parent.ID, Agent: "general", PermissionMode: "full_access"}
	env.sessions[parent.ID], env.sessions[child.ID] = parent, child
	pr := &activeRun{}
	env.running[parent.ID], env.running[child.ID] = pr, &activeRun{parentRun: pr}
	stale := *child
	tc := toolContext{env: env, session: &stale, depth: 1, rootPath: root, absWorkdir: root}
	if effect, _ := tc.liveToolPermission("write", "notes.md"); effect != "allow" {
		t.Fatal("fixture should initially allow writing")
	}
	ask := "ask"
	if _, err := env.UpdateSessionPermission(parent.ID, &ask, nil); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan ToolExecResult, 1)
	go func() {
		done <- executeTool(ctx, tc, "write", json.RawMessage(`{"path":"notes.md","content":"fixture"}`))
	}()
	var q *PermissionQuestion
	select {
	case ev := <-events:
		q = ev.Permission
	case result := <-done:
		t.Fatalf("child did not wait for permission: %+v", result)
	case <-ctx.Done():
		t.Fatal("child did not ask")
	}
	if q == nil || !q.IsSubagent || q.SessionID != child.ID {
		t.Fatalf("unexpected approval: %+v", q)
	}
	rules := []PermissionRule{{Action: "write", Resource: "*", Effect: "deny", Agent: "subagent"}}
	ids, err := env.UpdateSessionPermission(parent.ID, nil, &rules)
	if err != nil || len(ids) != 1 || ids[0] != q.ID {
		t.Fatalf("parent update did not close the child's prompt: %v %v", ids, err)
	}
	select {
	case result := <-done:
		if !result.IsError || !strings.Contains(result.Output, "拒绝") {
			t.Fatalf("child ignored revoked authorization: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("child still waiting for an answer")
	}
	if _, err := os.Stat(filepath.Join(root, "notes.md")); !os.IsNotExist(err) {
		t.Fatalf("child should not have written: %v", err)
	}
}

func TestToolUsesLivePermissionsRatherThanModelRequestSnapshot(t *testing.T) {
	root := t.TempDir()
	env := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	env.init()
	s := &Session{ID: "fixture", Agent: "build", PermissionMode: "full_access", Root: "work", Workdir: "/"}
	stale := *s
	env.sessions[s.ID] = s
	mode := "ask"
	rules := []PermissionRule{{Action: "write", Resource: "*", Effect: "deny"}}
	if _, err := env.UpdateSessionPermission(s.ID, &mode, &rules); err != nil {
		t.Fatal(err)
	}
	tc := toolContext{env: env, session: &stale, rootPath: root, absWorkdir: root}
	result := executeTool(context.Background(), tc, "write", json.RawMessage(`{"path":"notes.md","content":"fixture"}`))
	if !result.IsError || !strings.Contains(result.Output, "拒绝") {
		t.Fatalf("stale request permissions did not honor live deny: %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "notes.md")); !os.IsNotExist(err) {
		t.Fatalf("tool should not have written: %v", err)
	}
}

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
	g.allowedKeys["s\x00shell\x00npm *"] = 0
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

func TestPermissionAgentRolesNetworkAndLifecycle(t *testing.T) {
	g := NewPermissionGate()
	rules := []PermissionRule{
		{Action: "network", Resource: "*", Effect: "deny", Agent: "subagent"},
		{Action: "webfetch", Resource: "https://docs.example.com/*", Effect: "allow", Agent: "primary"},
		{Action: "shell", Resource: "npm test *", Effect: "allow", Agent: "primary", ExpiresAt: time.Now().Add(-time.Minute).UnixMilli()},
		{Action: "edit", Resource: "src/*", Effect: "deny", Agent: "general", Disabled: true},
	}

	// Primary agent allowed on matching webfetch URL; subagent denied on network.
	if eff, _ := g.EvaluateWithContext("s1", "build", false, "ask", "webfetch", "https://docs.example.com/guide", rules); eff != "allow" {
		t.Fatalf("primary webfetch = %q want allow", eff)
	}
	if eff, _ := g.EvaluateWithContext("s1", "general", true, "auto", "webfetch", "https://docs.example.com/guide", rules); eff != "deny" {
		t.Fatalf("subagent webfetch = %q want deny", eff)
	}

	// Expired rule does not apply (falls back to ask).
	if eff, _ := g.EvaluateWithContext("s1", "build", false, "ask", "shell", "npm test --all", rules); eff != "ask" {
		t.Fatalf("expired shell rule = %q want ask", eff)
	}

	// Disabled rule does not apply.
	if eff, _ := g.EvaluateWithContext("s1", "general", true, "auto", "edit", "src/a.go", rules); eff != "allow" {
		t.Fatalf("disabled rule = %q want allow", eff)
	}

	// Default ask mode asks for webfetch and remembers host scope on Always.
	if eff, reason := g.EvaluateWithContext("s2", "build", false, "ask", "webfetch", "https://api.example.org/v1", nil); eff != "ask" || PermissionReasonCode(reason) != "network_access" {
		t.Fatalf("default webfetch = (%q, %q)", eff, reason)
	}
	if got := AlwaysAllowScope("webfetch", "https://api.example.org/v1"); got != "https://api.example.org/*" {
		t.Fatalf("webfetch AlwaysAllowScope = %q", got)
	}

	// TTL grant expires and revoke-all clears session grants.
	g.allowedKeys["s2\x00shell\x00git *"] = time.Now().Add(time.Hour).UnixMilli()
	g.allowedKeys["s2\x00read\x00*"] = time.Now().Add(-time.Second).UnixMilli()
	grants := g.SessionGrants("s2", "", "", false)
	if len(grants) != 1 || grants[0].Resource != "git *" || grants[0].ExpiresAt == 0 {
		t.Fatalf("unexpected grants: %+v", grants)
	}
	if left := g.SessionGrants("s2", "*", "*", true); len(left) != 0 {
		t.Fatalf("expected all grants revoked, got %+v", left)
	}

	// Full Access mode bypasses ask prompts for sensitive files, high-risk shell, and network,
	// while still honoring explicit deny rules, plan/explore read-only guards, and doom_loop.
	if eff, _ := g.EvaluateWithContext("s3", "build", false, "full_access", "read", ".env", nil); eff != "allow" {
		t.Fatalf("full_access .env = %q want allow", eff)
	}
	if eff, _ := g.EvaluateWithContext("s3", "build", false, "full_access", "shell", "rm -rf /tmp/test", nil); eff != "allow" {
		t.Fatalf("full_access high-risk shell = %q want allow", eff)
	}
	if eff, _ := g.EvaluateWithContext("s3", "build", false, "full_access", "webfetch", "https://example.com", nil); eff != "allow" {
		t.Fatalf("full_access webfetch = %q want allow", eff)
	}
	if eff, _ := g.EvaluateWithContext("s3", "build", false, "full_access", "shell", "git push origin main", []PermissionRule{{Action: "shell", Resource: "git push *", Effect: "deny"}}); eff != "deny" {
		t.Fatalf("full_access explicit deny = %q want deny", eff)
	}
	if eff, _ := g.EvaluateWithContext("s3", "plan", false, "full_access", "edit", "a.go", nil); eff != "deny" {
		t.Fatalf("full_access plan edit = %q want deny", eff)
	}
	if eff, _ := g.EvaluateWithContext("s3", "build", false, "full_access", "doom_loop", "read x", nil); eff != "ask" {
		t.Fatalf("full_access doom_loop = %q want ask", eff)
	}

	// Switching to full_access immediately resolves pending non-doom_loop prompts.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	askErr := make(chan error, 1)
	go func() {
		askErr <- g.Ask(ctx, PermissionQuestion{
			ID:        "perm_live_1",
			SessionID: "s_live",
			Action:    "shell",
			Resource:  "echo hi",
		}, nil)
	}()
	// Wait briefly until Ask registers the pending question.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if ids := g.ResolveSessionPending("s_live", "build", false, "full_access", nil); len(ids) == 1 && ids[0] == "perm_live_1" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := <-askErr; err != nil {
		t.Fatalf("pending Ask after full_access switch failed: %v", err)
	}
}

func TestResolveSessionPendingAppliesChangedRulesOnlyToTargetSession(t *testing.T) {
	g := NewPermissionGate()
	queue := func(id, session, action, resource string) chan PermissionDecision {
		ch := make(chan PermissionDecision, 1)
		g.pending[id] = &pendingPermission{question: PermissionQuestion{
			ID: id, SessionID: session, Action: action, Resource: resource,
		}, ch: ch}
		return ch
	}
	allow := queue("allow", "parent", "write", "notes.md")
	deny := queue("deny", "parent", "write", "locked.md")
	ask := queue("ask", "parent", "write", "draft.md")
	child := queue("child", "child", "write", "notes.md")
	ids := g.ResolveSessionPending("parent", "build", false, "ask", []PermissionRule{
		{Action: "write", Resource: "notes.md", Effect: "allow"},
		{Action: "write", Resource: "locked.md", Effect: "deny"},
	})
	if len(ids) != 2 || len(allow) != 1 || len(deny) != 1 || len(ask) != 0 || len(child) != 0 {
		t.Fatalf("wrong pending resolutions: %v", ids)
	}
	if !(<-allow).Allow || (<-deny).Allow {
		t.Fatal("rule changes must authorize or reject as specified")
	}
}
