//go:build linux

package ai

import (
	"context"
	"encoding/base64"
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

func oauthStandIn(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(handler)
	oldIssuer, oldCodex := openAIIssuer, codexBaseURL
	openAIIssuer, codexBaseURL = s.URL, s.URL+"/codex"
	t.Cleanup(func() { openAIIssuer, codexBaseURL = oldIssuer, oldCodex; s.Close() })
	return s
}

func TestDeviceAuthorizationLifecycle(t *testing.T) {
	ctx := context.Background()
	polls := 0
	oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("method = %s", r.Method)
		}
		switch r.URL.Path {
		case "/api/accounts/deviceauth/usercode":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["client_id"] != OpenAIDeviceClientID {
				t.Error("wrong client ID")
			}
			fmt.Fprint(w, `{"device_auth_id":"device-fixture","user_code":"ABCD-EFGH","interval":"5"}`)
		case "/api/accounts/deviceauth/token":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["device_auth_id"] != "device-fixture" || body["user_code"] != "ABCD-EFGH" {
				t.Error("wrong poll body")
			}
			polls++
			if polls == 1 {
				w.WriteHeader(403)
				return
			}
			if polls == 2 {
				w.WriteHeader(404)
				return
			}
			fmt.Fprint(w, `{"authorization_code":"authorization-fixture","code_verifier":"verifier-fixture"}`)
		case "/oauth/token":
			_ = r.ParseForm()
			if r.Form.Get("grant_type") != "authorization_code" || r.Form.Get("code") != "authorization-fixture" || r.Form.Get("code_verifier") != "verifier-fixture" || r.Form.Get("redirect_uri") != openAIIssuer+"/deviceauth/callback" || r.Form.Get("client_id") != OpenAIDeviceClientID {
				t.Error("wrong token exchange form")
			}
			fmt.Fprint(w, `{"access_token":"access-fixture","refresh_token":"refresh-fixture","expires_in":3600}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	})
	d, err := beginOpenAIDevice(ctx, false, nil)
	if err != nil || d.IntervalMS != 8000 || d.URL != openAIIssuer+"/codex/device" || d.ExpiresAt <= time.Now().UnixMilli() {
		t.Fatalf("begin: %+v %v", d, err)
	}
	for i := 0; i < 2; i++ {
		c, err := pollOpenAIDevice(ctx, false, nil, d.DeviceAuthID, d.UserCode)
		if c != nil || err != nil {
			t.Fatalf("pending: %v %v", c != nil, err)
		}
	}
	c, err := pollOpenAIDevice(ctx, false, nil, d.DeviceAuthID, d.UserCode)
	if err != nil || c.Access != "access-fixture" || c.Refresh != "refresh-fixture" || c.Expires <= time.Now().UnixMilli() {
		t.Fatal("token exchange failed")
	}
}

func TestDeviceIntervalsAndSafeErrors(t *testing.T) {
	for _, tc := range []struct {
		interval string
		expected int
	}{{`0`, 8000}, {`"bad"`, 8000}, {`999`, 63000}, {`"10"`, 13000}} {
		t.Run(tc.interval, func(t *testing.T) {
			oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprintf(w, `{"device_auth_id":"fixture","user_code":"code","interval":%s}`, tc.interval)
			})
			d, err := beginOpenAIDevice(context.Background(), false, nil)
			if err != nil || d.IntervalMS != tc.expected {
				t.Fatalf("interval = %d, err=%v", d.IntervalMS, err)
			}
		})
	}
	t.Run("safe upstream body", func(t *testing.T) {
		oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(400)
			fmt.Fprint(w, "secret-upstream-fixture")
		})
		_, err := beginOpenAIDevice(context.Background(), false, nil)
		if err == nil || strings.Contains(err.Error(), "secret-upstream-fixture") {
			t.Fatal("unsafe error")
		}
	})
	t.Run("redirect rejected", func(t *testing.T) {
		forwarded := false
		other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded = true }))
		defer other.Close()
		oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, other.URL, 307) })
		_, err := beginOpenAIDevice(context.Background(), false, nil)
		if err == nil || forwarded {
			t.Fatal("OAuth followed redirect")
		}
	})
}

func TestRefreshRPCAndAccountClaims(t *testing.T) {
	jwt := func(claims string) string {
		return "e30." + base64.RawURLEncoding.EncodeToString([]byte(claims)) + ".fixture"
	}
	for _, claims := range []string{`{"chatgpt_account_id":"account-fixture"}`, `{"https://api.openai.com/auth":{"chatgpt_account_id":"account-fixture"}}`, `{"organizations":[{"id":"account-fixture"}]}`} {
		if accountClaim(jwt(claims)) != "account-fixture" {
			t.Error("claim not found")
		}
	}
	if accountClaim("not-a-jwt") != "" {
		t.Error("invalid JWT accepted")
	}
	oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "refresh_token" || r.Form.Get("refresh_token") != "old-refresh-fixture" {
			t.Error("bad refresh form")
		}
		fmt.Fprint(w, `{"access_token":"new-access-fixture","expires_in":3600}`)
	})
	e := &Env{}
	sub := e.subscribe()
	defer e.unsubscribe(sub)
	result, err := (svc{e}).opAuthRefresh(context.Background(), json.RawMessage(`{"refresh":"old-refresh-fixture","account_id":"old-account-fixture"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(result)
	var out struct {
		Credential OAuthCredential `json:"credential"`
	}
	_ = json.Unmarshal(b, &out)
	if out.Credential.Access != "new-access-fixture" || out.Credential.Refresh != "old-refresh-fixture" || out.Credential.AccountID != "old-account-fixture" {
		t.Fatal("refresh lost unchanged metadata")
	}
	select {
	case <-sub:
		t.Fatal("credentials broadcast")
	default:
	}
}

func TestSubscriptionResponsesRouting(t *testing.T) {
	forwarded := false
	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded = true }))
	defer evil.Close()
	calls := 0
	oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/codex/responses" || r.Header.Get("Authorization") != "Bearer access-fixture" || r.Header.Get("chatgpt-account-id") != "account-fixture" || r.Header.Get("originator") != "opencode" || r.Header.Get("session-id") != "parent-fixture" {
			t.Error("subscription routing/headers wrong")
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["store"] != false || body["stream"] != true || body["max_output_tokens"] != nil || body["temperature"] != nil {
			t.Error("unsupported subscription body")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"hello\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"total_tokens\":110}}}\n\n")
	})
	temp := 0.3
	cfg := ProviderConfig{AuthMode: ChatGPTAuthMode, APIKey: "access-fixture", AccountID: "account-fixture", BaseURL: evil.URL, Protocol: "anthropic-messages", Model: "gpt-6.1-sol", MaxOutputTokens: 20, Headers: map[string]string{"Authorization": "evil", "chatgpt-account-id": "evil"}}
	r, err := StreamLLM(context.Background(), LLMRequest{SessionID: "child-fixture", AffinityID: "parent-fixture", Provider: cfg, MaxTokens: 30, Temperature: &temp}, nil, nil)
	if err != nil || r.Usage.InputTokens != 100 || calls != 1 || forwarded {
		t.Fatalf("subscription stream failed: calls=%d err=%v", calls, err)
	}
	cfg.ExpiresAt = time.Now().Add(-time.Minute).UnixMilli()
	if _, err := StreamLLM(context.Background(), LLMRequest{Provider: cfg}, nil, nil); err == nil || calls != 1 {
		t.Fatal("expired access used")
	}
	cfg.ExpiresAt = 0
	models, err := FetchModels(context.Background(), cfg, nil)
	if err != nil || len(models) == 0 || calls != 1 {
		t.Fatal("subscription catalog must not call API key endpoint")
	}
}

func TestRuntimeContextAllowlist(t *testing.T) {
	cfg := ProviderConfig{ID: "provider", Name: "ChatGPT", Model: "gpt-6.1-sol", Protocol: "openai-responses", AuthMode: ChatGPTAuthMode, APIKey: "secret-access-fixture", AccountID: "secret-account-fixture", Headers: map[string]string{"secret-header-fixture": "value"}}
	s := &Session{Messages: []Message{{Role: "user", Parts: []Part{{Type: "text", Text: strings.Repeat("hello ", 100)}}}}, TotalUsage: Usage{TotalTokens: 9999999}, LastInputToks: 100}
	c := activeContext(s, cfg, 500)
	if c.Limit != 500000 || c.Tokens < 500 || c.Tokens >= s.TotalUsage.TotalTokens || !c.Estimated || c.LastInput != 0 {
		t.Fatal("context confused with cumulative usage")
	}
	if subscriptionContextCap("gpt-5.2-codex") != 272000 || subscriptionContextCap("gpt-7") != 500000 {
		t.Fatal("OpenCode caps differ")
	}
	s.Runtime, s.Context = runtimeInfo(cfg), c
	s.Messages = append(s.Messages, Message{Role: "assistant", Runtime: runtimeInfo(cfg)})
	b, _ := json.Marshal(s)
	for _, secret := range []string{"secret-access-fixture", "secret-account-fixture", "secret-header-fixture"} {
		if strings.Contains(string(b), secret) {
			t.Fatal("runtime metadata leaked credentials")
		}
	}
}

func TestSubscriptionAuxiliaryCalls(t *testing.T) {
	calls := 0
	oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/codex/responses" || r.Header.Get("chatgpt-account-id") != "secret-account-fixture" || r.Header.Get("Authorization") != "Bearer secret-access-fixture" {
			t.Error("auxiliary request lost OAuth routing")
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["max_output_tokens"] != nil || body["temperature"] != nil {
			t.Error("auxiliary request used unsupported parameters")
		}
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"summary\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"total_tokens\":110}}}\n\n")
	})
	work := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	e.init()
	e.sessions["session-fixture"] = &Session{ID: "session-fixture", Root: "work", Workdir: "/", Agent: "build", Title: "New", LastInputToks: 40000, Context: &ContextInfo{Tokens: 40000, LastInput: 40000, Overhead: 500}, Messages: []Message{{ID: "user-fixture", Role: "user", Parts: []Part{{Type: "text", Text: strings.Repeat("long history ", 20000)}}}}}
	cfg := ProviderConfig{Name: "ChatGPT", Protocol: "openai-responses", Model: "gpt-6.1-sol", AuthMode: ChatGPTAuthMode, APIKey: "secret-access-fixture", AccountID: "secret-account-fixture", ExpiresAt: time.Now().Add(time.Hour).UnixMilli()}
	e.generateTitleAsync("session-fixture", "a prompt", cfg)
	if e.sessions["session-fixture"].Title != "summary" {
		t.Fatal("title generation failed")
	}
	msg, err := e.CompactSession(context.Background(), "session-fixture", cfg)
	if err != nil || msg.Runtime == nil || msg.Runtime.ProviderName != "ChatGPT" || calls != 2 {
		t.Fatalf("compaction failed: %v", err)
	}
	s := e.sessions["session-fixture"]
	if s.Context.LastInput != 0 || s.Context.Tokens >= 40000 || s.Context.Limit != 500000 {
		t.Fatal("compaction did not reset active context")
	}
	next := activeContext(s, cfg, 500)
	if next.LastInput != 0 {
		t.Fatal("compaction estimate mislabeled as exact input")
	}
	b, err := os.ReadFile(filepath.Join(e.StateDir, "ai", "sessions", "session-fixture.json"))
	if err != nil || strings.Contains(string(b), "secret-access-fixture") || strings.Contains(string(b), "secret-account-fixture") {
		t.Fatal("auxiliary call persisted credentials")
	}
}

func TestSubscriptionSafeFailures(t *testing.T) {
	for _, mode := range []string{"http", "stream", "overflow", "disconnect", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			forwarded := false
			other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded = true }))
			defer other.Close()
			oauthStandIn(t, func(w http.ResponseWriter, r *http.Request) {
				switch mode {
				case "http":
					w.WriteHeader(401)
					fmt.Fprint(w, "secret-upstream-fixture")
				case "stream":
					fmt.Fprint(w, "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"secret-upstream-fixture\"}}}\n\n")
				case "overflow":
					w.WriteHeader(400)
					fmt.Fprint(w, `{"error":{"code":"context_length_exceeded","message":"secret-upstream-fixture"}}`)
				case "redirect":
					http.Redirect(w, r, other.URL, 307)
				}
			})
			_, err := StreamLLM(context.Background(), LLMRequest{Provider: ProviderConfig{AuthMode: ChatGPTAuthMode, APIKey: "secret-access-fixture", Model: "gpt-6.1-sol"}}, nil, nil)
			if err == nil || strings.Contains(err.Error(), "secret-upstream-fixture") || strings.Contains(err.Error(), "secret-access-fixture") || forwarded {
				t.Fatal("unsafe subscription failure")
			}
			if mode == "overflow" && !IsContextOverflowError(err) {
				t.Fatal("safe error lost compaction classification")
			}
		})
	}
}
