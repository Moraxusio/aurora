//go:build linux || windows

package ai

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

func TestRetryAfterHeaderIsHonoured(t *testing.T) {
	cases := []struct {
		header string
		want   time.Duration
	}{
		{"", 0},
		{"2", 2 * time.Second},
		{"  7 ", 7 * time.Second},
		{"0", 0},
		{"-3", 0},
		{"abc", 0},
		{"3600", maxRetryWait},
	}
	for _, c := range cases {
		h := http.Header{}
		if c.header != "" {
			h.Set("Retry-After", c.header)
		}
		if got := retryAfter(h, time.Now()); got != c.want {
			t.Errorf("Retry-After %q = %v, want %v", c.header, got, c.want)
		}
	}
	h := http.Header{}
	h.Set("Retry-After", time.Now().Add(4*time.Second).UTC().Format(http.TimeFormat))
	if got := retryAfter(h, time.Now()); got < 2*time.Second || got > 5*time.Second {
		t.Errorf("HTTP-date Retry-After = %v, want about 4s", got)
	}
}

func TestStatusErrorCarriesRetryAfter(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) < 3 {
			w.Header().Set("Retry-After", "1")
			http.Error(w, `{"error":{"message":"slow down"}}`, http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintln(w, `data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`)
		fmt.Fprintln(w)
		fmt.Fprintln(w, `data: [DONE]`)
		fmt.Fprintln(w)
	}))
	defer srv.Close()
	start := time.Now()
	resp, err := StreamLLM(context.Background(), LLMRequest{
		SessionID: "ses_retry",
		Provider:  ProviderConfig{Protocol: "openai-chat", BaseURL: srv.URL, APIKey: "k", Model: "gpt-4o"},
		Messages:  []Message{{ID: "m", Role: "user", Parts: []Part{{Type: "text", Text: "hi"}}}},
	}, nil, nil)
	if err != nil {
		t.Fatalf("two 429s with Retry-After should be retried: %v", err)
	}
	if attempts.Load() != 3 || len(resp.Parts) != 1 || resp.Parts[0].Text != "ok" {
		t.Fatalf("attempts=%d resp=%+v", attempts.Load(), resp)
	}
	// A Retry-After smaller than our own backoff must not shorten it: 1.5s + 3.5s.
	if el := time.Since(start); el < 4900*time.Millisecond {
		t.Fatalf("a small Retry-After shortened the backoff: finished in %v", el)
	}
}

func TestLargerRetryAfterLengthensTheWait(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) == 1 {
			w.Header().Set("Retry-After", "3")
			http.Error(w, `{"error":{"message":"busy"}}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintln(w, `data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`)
		fmt.Fprintln(w)
		fmt.Fprintln(w, `data: [DONE]`)
		fmt.Fprintln(w)
	}))
	defer srv.Close()
	start := time.Now()
	_, err := StreamLLM(context.Background(), LLMRequest{
		SessionID: "ses_retry2",
		Provider:  ProviderConfig{Protocol: "openai-chat", BaseURL: srv.URL, APIKey: "k", Model: "gpt-4o"},
		Messages:  []Message{{ID: "m", Role: "user", Parts: []Part{{Type: "text", Text: "hi"}}}},
	}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	// 3s asked for, against a 1.5s backoff: the longer one wins.
	if el := time.Since(start); el < 2900*time.Millisecond {
		t.Fatalf("Retry-After 3 ignored: retried after %v", el)
	}
}

func TestPermissionReasonsForTheClient(t *testing.T) {
	g := NewPermissionGate()
	cases := []struct {
		agent, mode, action, resource string
		wantEff, wantCode             string
	}{
		{"build", "ask", "edit", "a.go", "ask", "file_modification"},
		{"build", "ask", "write", "a.go", "ask", "file_modification"},
		{"build", "ask", "shell", "make build", "ask", "shell_command"},
		{"build", "auto", "shell", "rm -rf /", "ask", "high_risk_shell"},
		{"build", "ask", "read", ".env", "ask", "sensitive_file"},
		{"plan", "ask", "edit", "a.go", "deny", "plan_read_only"},
		{"explore", "ask", "write", "a.go", "deny", "explore_read_only"},
		{"build", "ask", "doom_loop", "read x", "ask", "repeated_call"},
	}
	for _, c := range cases {
		eff, reason := g.Evaluate("s", c.agent, c.mode, c.action, c.resource)
		if eff != c.wantEff {
			t.Errorf("%s/%s/%s: effect %q want %q", c.agent, c.mode, c.action, eff, c.wantEff)
			continue
		}
		if code := PermissionReasonCode(reason); code != c.wantCode {
			t.Errorf("%s/%s/%s: code %q want %q (reason %q)", c.agent, c.mode, c.action, code, c.wantCode, reason)
		}
	}
	if PermissionReasonCode("something new") != "" {
		t.Error("unknown reasons must map to no code")
	}
}

func TestOrderedPermissionRulesLastMatchWins(t *testing.T) {
	g := NewPermissionGate()
	rules := []PermissionRule{
		{Action: "shell", Resource: "*", Effect: "ask"},
		{Action: "shell", Resource: "git status *", Effect: "allow"},
		{Action: "shell", Resource: "git push *", Effect: "deny"},
	}
	if got, _ := g.EvaluateWithRules("s", "build", "ask", "shell", "git status --short", rules); got != "allow" {
		t.Fatalf("routine shell rule = %q", got)
	}
	if got, _ := g.EvaluateWithRules("s", "build", "ask", "shell", "git push origin main", rules); got != "deny" {
		t.Fatalf("deny shell rule = %q", got)
	}
	if got, _ := g.EvaluateWithRules("s", "build", "ask", "shell", "npm test", rules); got != "ask" {
		t.Fatalf("fallback shell rule = %q", got)
	}
}

func TestWildcardAllowCannotBypassSensitiveOrHighRiskGuard(t *testing.T) {
	g := NewPermissionGate()
	rules := []PermissionRule{
		{Action: "*", Resource: "*", Effect: "allow"},
	}
	if got, _ := g.EvaluateWithRules("s", "build", "auto", "read", ".env", rules); got != "ask" {
		t.Fatalf("wildcard allow bypassed secret guard: %q", got)
	}
	if got, _ := g.EvaluateWithRules("s", "build", "auto", "shell", "rm -rf /", rules); got != "ask" {
		t.Fatalf("wildcard allow bypassed high-risk guard: %q", got)
	}
}

func TestAlwaysAllowScopeIsExplained(t *testing.T) {
	cases := []struct {
		action, resource, want string
	}{
		{"shell", "git status --short", "git *"},
		{"shell", "  make   build ", "make *"},
		{"shell", "", "*"},
		{"edit", "src/a.go", "src/*"},
		{"write", "src/b.go", "src/*"},
	}
	for _, c := range cases {
		if got := savePattern(c.action, c.resource); got != c.want {
			t.Errorf("savePattern(%q,%q) = %q want %q", c.action, c.resource, got, c.want)
		}
		if got := AlwaysAllowScope(c.action, c.resource); got != c.want {
			t.Errorf("AlwaysAllowScope(%q,%q) = %q want %q", c.action, c.resource, got, c.want)
		}
	}
}

func TestPermissionQuestionCarriesScopeAndCode(t *testing.T) {
	g := NewPermissionGate()
	q := PermissionQuestion{ID: "p1", SessionID: "s", Action: "shell", Resource: "git push origin main", Reason: "Shell command execution requires approval"}
	emitted := make(chan PermissionQuestion, 1)
	done := make(chan error, 1)
	go func() {
		done <- g.Ask(context.Background(), q, func(pq PermissionQuestion) { emitted <- pq })
	}()
	select {
	case pq := <-emitted:
		if pq.AlwaysScope != "git *" {
			t.Errorf("AlwaysScope = %q want %q", pq.AlwaysScope, "git *")
		}
		if pq.ReasonCode != "shell_command" {
			t.Errorf("ReasonCode = %q want shell_command", pq.ReasonCode)
		}
		if pq.Reason != q.Reason {
			t.Errorf("Reason text must stay for older clients, got %q", pq.Reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no question emitted")
	}
	if !g.Resolve("p1", PermissionDecision{Allow: true}) {
		t.Fatal("resolve failed")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := g.PendingForSession("s"); got != nil {
		t.Fatalf("question left pending: %+v", got)
	}
}

func TestCompactionPromptFollowsTheConversationLanguage(t *testing.T) {
	chinese := []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "请检查并更新登录逻辑，然后运行测试"}}}}
	english := []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "please check the login code and run the tests"}}}}
	if got := conversationLanguage(chinese); got != "简体中文" {
		t.Errorf("chinese conversation detected as %q", got)
	}
	if got := conversationLanguage(english); got != "" {
		t.Errorf("english conversation must not force a language, got %q", got)
	}
	p := buildCompactionPrompt(false, "简体中文")
	if !strings.Contains(p, "简体中文") || !strings.Contains(p, "## Objective") {
		t.Errorf("language instruction missing or template headings changed:\n%s", p)
	}
	if strings.Contains(buildCompactionPrompt(false, ""), "Write the summary in") {
		t.Error("no language instruction expected for an English conversation")
	}
	// Headings stay English so the summary is parseable by later compactions.
	for _, h := range []string{"## Objective", "## Requirements", "## Decisions", "## Work State", "## Next Move", "## Relevant Files", "## Important Context"} {
		if !strings.Contains(p, h) {
			t.Errorf("template heading %q lost", h)
		}
	}
}

func TestEstimateTokensCountsCJKHeavier(t *testing.T) {
	ascii := strings.Repeat("abcd", 100)
	cjk := strings.Repeat("你好世界", 100)
	if a, c := EstimateTokens(ascii), EstimateTokens(cjk); c <= a {
		t.Errorf("400 CJK chars (%d) must estimate above 400 ASCII chars (%d)", c, a)
	}
	if got := EstimateTokens(""); got != 0 {
		t.Errorf("empty = %d", got)
	}
	if got := EstimateTokens("abcd"); got != 1 {
		t.Errorf("4 ascii bytes = %d tokens, want 1", got)
	}
	// Never undercount below the old byte-based estimate.
	mixed := "login 登录 flow"
	if got, old := EstimateTokens(mixed), (len(mixed)+3)/4; got < old {
		t.Errorf("mixed text estimate %d fell below the byte estimate %d", got, old)
	}
}

func TestDefaultContextWindowMarkedAsGuess(t *testing.T) {
	cw, src := contextLimit(ProviderConfig{Model: "gpt-6.1-sol"})
	if cw <= 0 {
		t.Fatalf("context window = %d", cw)
	}
	if src != "default" {
		t.Errorf("a window guessed from the model name must be reported as default, got %q", src)
	}
	_, src = contextLimit(ProviderConfig{Model: "gpt-6.1-sol", ContextWindow: 123456})
	if src != "configured" {
		t.Errorf("configured window reported as %q", src)
	}
}

func TestTruncateOutputUTF8AndSingleLongLineTail(t *testing.T) {
	// Single-line CJK string longer than MaxOutputBytes: head must keep valid UTF-8.
	longHead := strings.Repeat("中", MaxOutputBytes)
	head := TruncateOutput(longHead, "", "head")
	if !head.Truncated || !utf8.ValidString(head.Content) {
		t.Fatalf("head truncation produced invalid UTF-8 or missed truncation: valid=%v", utf8.ValidString(head.Content))
	}

	// Single-line string longer than MaxOutputBytes: tail must keep suffix, not empty preview.
	longTail := strings.Repeat("你", MaxOutputBytes) + "END_MARKER"
	tail := TruncateOutput(longTail, "", "tail")
	if !tail.Truncated || !utf8.ValidString(tail.Content) || !strings.Contains(tail.Content, "END_MARKER") {
		t.Fatalf("tail single-line truncation lost suffix or broke UTF-8: %q", tail.Content[:min(len(tail.Content), 120)])
	}
}

func TestStreamCancelPreservesPartialContentAcrossProtocols(t *testing.T) {
	for _, proto := range []string{"openai-chat", "openai-responses", "anthropic-messages"} {
		t.Run(proto, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				fl, _ := w.(http.Flusher)
				switch proto {
				case "openai-chat":
					fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\",\"content\":\"hello \"}}]}\n\n")
				case "openai-responses":
					fmt.Fprint(w, "data: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"item_id\":\"rs_1\",\"delta\":\"think\"}\n\n")
					fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"item_id\":\"msg_1\",\"delta\":\"hello \"}\n\n")
				default:
					fmt.Fprint(w, "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"think\"}}\n\n")
					fmt.Fprint(w, "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"hello \"}}\n\n")
				}
				if fl != nil {
					fl.Flush()
				}
				<-r.Context().Done()
			}))
			defer srv.Close()

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			sawText := make(chan struct{}, 1)
			resp, err := StreamLLM(ctx, LLMRequest{
				Provider: ProviderConfig{Protocol: proto, BaseURL: srv.URL, Model: "fixture"},
				Messages: []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "hi"}}}},
			}, nil, func(d LLMDelta) {
				if d.Type == "text" {
					select {
					case sawText <- struct{}{}:
					default:
					}
					cancel()
				}
			})
			select {
			case <-sawText:
			case <-time.After(3 * time.Second):
				t.Fatal("did not observe streamed text")
			}
			if err == nil || resp.Finish != "aborted" {
				t.Fatalf("expected aborted partial response, got finish=%q err=%v", resp.Finish, err)
			}
			var gotText, gotReason bool
			for _, p := range resp.Parts {
				if p.Type == "text" && strings.Contains(p.Text, "hello ") {
					gotText = true
				}
				if p.Type == "reasoning" && strings.Contains(p.Text, "think") {
					gotReason = true
				}
			}
			if !gotText || !gotReason {
				t.Fatalf("lost partial parts on cancel: %+v", resp.Parts)
			}
		})
	}
}

func TestManualCompactionFallsBackToOverflowMode(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		if n == 1 {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error":{"message":"maximum context length exceeded"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"## Objective\\n- done\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer srv.Close()

	work := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	e.init()
	e.sessions["ses_compact"] = &Session{
		ID:      "ses_compact",
		Root:    "work",
		Workdir: "/",
		Agent:   "build",
		Messages: []Message{
			{ID: "u1", Role: "user", Parts: []Part{{Type: "text", Text: "summarize this"}}},
			{ID: "a1", Role: "assistant", Parts: []Part{{Type: "text", Text: "working on it"}}},
		},
	}
	msg, err := e.CompactSession(context.Background(), "ses_compact", ProviderConfig{
		Protocol: "openai-chat",
		BaseURL:  srv.URL,
		Model:    "gpt-4o",
	})
	if err != nil {
		t.Fatalf("expected overflow fallback to succeed, got: %v", err)
	}
	if calls.Load() != 2 || len(msg.Parts) == 0 || !strings.Contains(msg.Parts[0].Text, "## Objective") {
		t.Fatalf("unexpected compaction calls=%d msg=%+v", calls.Load(), msg)
	}
}

func TestRevertSessionRestoresTodosAndStripsOrphanedReminder(t *testing.T) {
	work := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	e.init()
	e.sessions["ses_rev"] = &Session{
		ID:      "ses_rev",
		Root:    "work",
		Workdir: "/",
		Agent:   "plan",
		Todos:   []TodoItem{{ID: "2", Content: "future", Status: "in_progress"}},
		Messages: []Message{
			{ID: "u1", Role: "user", Agent: "build", Parts: []Part{{Type: "text", Text: "step 1"}}},
			{ID: "a1", Role: "assistant", Agent: "build", Parts: []Part{{Type: "tool-result", ToolName: "todowrite", Metadata: map[string]any{"todos": []TodoItem{{ID: "1", Content: "kept", Status: "completed"}}}}}},
			{ID: "rem", Role: "user", Parts: []Part{{Type: "text", Text: "<system-reminder>\nYou are in Plan mode.\n</system-reminder>"}}},
			{ID: "u2", Role: "user", Agent: "plan", Parts: []Part{{Type: "text", Text: "step 2"}}},
		},
	}
	reverted, _, err := e.RevertSession(context.Background(), "ses_rev", "u2", false)
	if err != nil {
		t.Fatalf("RevertSession failed: %v", err)
	}
	if len(reverted.Messages) != 2 {
		t.Fatalf("expected orphaned reminder stripped, got %d messages", len(reverted.Messages))
	}
	if reverted.Agent != "build" {
		t.Fatalf("expected agent restored to build, got %q", reverted.Agent)
	}
	if len(reverted.Todos) != 1 || reverted.Todos[0].ID != "1" {
		t.Fatalf("expected todos restored to step 1, got %+v", reverted.Todos)
	}
}
