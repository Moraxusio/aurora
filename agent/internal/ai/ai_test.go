//go:build linux

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
	"sync/atomic"
	"testing"
	"time"
)

func TestApplyEditThreeTierAndCRLF(t *testing.T) {
	// 1. Exact CRLF + UTF-8 BOM preservation
	src := "\xef\xbb\xbffunc hello() {\r\n\tprintln(\"one\")\r\n\tprintln(\"two\")\r\n}\r\n"
	res, err := ApplyEdit("main.go", src, "\tprintln(\"one\")\n\tprintln(\"two\")", "\tprintln(\"one\")\n\tprintln(\"three\")", false)
	if err != nil {
		t.Fatalf("ApplyEdit CRLF failed: %v", err)
	}
	if !strings.HasPrefix(res.Content, "\xef\xbb\xbf") {
		t.Fatalf("UTF-8 BOM was lost")
	}
	if !strings.Contains(res.Content, "println(\"three\")\r\n") {
		t.Fatalf("CRLF line ending was not preserved: %q", res.Content)
	}
	if res.Replacements != 1 || res.Diff.Additions != 1 || res.Diff.Deletions != 1 {
		t.Fatalf("unexpected diff stats: %+v", res.Diff)
	}

	// 2. Tier-2 Unicode quote / dash normalization
	typoSrc := "const msg = “Hello — world”;\n"
	res2, err := ApplyEdit("msg.ts", typoSrc, `const msg = "Hello - world";`, `const msg = "Updated";`, false)
	if err != nil {
		t.Fatalf("Tier-2 unicode match failed: %v", err)
	}
	if res2.Content != "const msg = \"Updated\";\n" {
		t.Fatalf("unexpected Tier-2 result: %q", res2.Content)
	}

	// 3. Tier-3 trailing whitespace tolerance
	wsSrc := "lineA   \nlineB\t\t\nlineC\n"
	res3, err := ApplyEdit("ws.txt", wsSrc, "lineA\nlineB", "lineA\nlineB_mod", false)
	if err != nil {
		t.Fatalf("Tier-3 trailing whitespace match failed: %v", err)
	}
	if !strings.Contains(res3.Content, "lineB_mod\nlineC\n") {
		t.Fatalf("unexpected Tier-3 result: %q", res3.Content)
	}

	// 4. Miss hint shows closest lines
	_, missErr := ApplyEdit("main.go", "package main\n\nfunc targetFunc(x int) int {\n\treturn x + 1\n}\n", "func targetFunc(x int) int {\n\treturn x + 999\n}", "func targetFunc(x int) int {\n\treturn x\n}", false)
	if missErr == nil || !strings.Contains(missErr.Error(), "The closest lines in the file:") {
		t.Fatalf("expected closest-lines missHint, got: %v", missErr)
	}
}

func TestTruncateOutputSpillover(t *testing.T) {
	spill := t.TempDir()
	var big strings.Builder
	for i := 0; i < 2500; i++ {
		fmt.Fprintf(&big, "line %d: some log payload\n", i)
	}
	tr := TruncateOutput(big.String(), spill, "tail")
	if !tr.Truncated || tr.SavedPath == "" {
		t.Fatalf("expected truncated output with saved spillover file, got %+v", tr)
	}
	if _, err := os.Stat(tr.SavedPath); err != nil {
		t.Fatalf("spillover file missing: %v", err)
	}
	if !strings.Contains(tr.Content, "Full output saved to:") || !strings.Contains(tr.Content, "line 2499:") {
		t.Fatalf("tail truncation missing expected content: %s", tr.Content[:200])
	}
}

func TestProtocolsAndOpenCodeHeaders(t *testing.T) {
	// Verify OpenAI Chat, Anthropic Messages, and OpenAI Responses SSE + OpenCode headers
	t.Run("openai-chat", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("User-Agent") != OpenCodeUserAgent {
				t.Errorf("bad User-Agent: %s", r.Header.Get("User-Agent"))
			}
			if r.Header.Get("HTTP-Referer") != OpenCodeReferer || r.Header.Get("X-Title") != OpenCodeTitle {
				t.Errorf("missing OpenCode referer/title headers")
			}
			if r.Header.Get("x-opencode-session-id") != "ses_test" || r.Header.Get("x-session-affinity") != "ses_parent" {
				t.Errorf("missing session affinity headers: %v", r.Header)
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintln(w, `data: {"choices":[{"delta":{"reasoning_content":"Thinking..."}}]}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"choices":[{"delta":{"content":"Hello OpenCode"}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":80}}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: [DONE]`)
			fmt.Fprintln(w)
		}))
		defer srv.Close()

		resp, err := StreamLLM(context.Background(), LLMRequest{
			SessionID:  "ses_test",
			AffinityID: "ses_parent",
			Initiator:  "user",
			Provider: ProviderConfig{
				Protocol: "openai-chat",
				BaseURL:  srv.URL,
				APIKey:   "sk-test",
				Model:    "deepseek-reasoner",
			},
			System:   []string{"sys"},
			Messages: []Message{{ID: "m1", Role: "user", Parts: []Part{{Type: "text", Text: "hi"}}}},
		}, nil, nil)
		if err != nil {
			t.Fatalf("openai-chat failed: %v", err)
		}
		if len(resp.Parts) != 2 || resp.Parts[0].Type != "reasoning" || resp.Parts[1].Text != "Hello OpenCode" {
			t.Fatalf("unexpected parts: %+v", resp.Parts)
		}
		if resp.Usage.CacheReadTokens != 80 || resp.Usage.InputTokens != 100 {
			t.Fatalf("unexpected usage: %+v", resp.Usage)
		}
	})

	t.Run("anthropic-messages", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("anthropic-version") != "2023-06-01" {
				t.Errorf("missing anthropic-version")
			}
			if !strings.Contains(r.Header.Get("anthropic-beta"), "interleaved-thinking-2025-05-14") {
				t.Errorf("missing interleaved-thinking beta: %s", r.Header.Get("anthropic-beta"))
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintln(w, `event: message_start`)
			fmt.Fprintln(w, `data: {"type":"message_start","message":{"usage":{"input_tokens":25,"cache_read_input_tokens":100}}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan step"}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_abc"}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read"}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.go\"}"}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"message_stop"}`)
			fmt.Fprintln(w)
		}))
		defer srv.Close()

		resp, err := StreamLLM(context.Background(), LLMRequest{
			SessionID: "ses_anth",
			Provider: ProviderConfig{
				Protocol:        "anthropic-messages",
				BaseURL:         srv.URL,
				APIKey:          "sk-ant-test",
				Model:           "claude-sonnet-4-5",
				ReasoningEffort: "medium",
			},
			System:   []string{"sys"},
			Messages: []Message{{ID: "m1", Role: "user", Parts: []Part{{Type: "text", Text: "check a.go"}}}},
		}, nil, nil)
		if err != nil {
			t.Fatalf("anthropic-messages failed: %v", err)
		}
		if resp.Finish != "tool-calls" || len(resp.Parts) != 2 {
			t.Fatalf("unexpected anthropic response: %+v", resp)
		}
		if resp.Parts[0].Signature != "sig_abc" || resp.Parts[1].ToolName != "read" {
			t.Fatalf("unexpected anthropic parts: %+v", resp.Parts)
		}
		if resp.Usage.InputTokens != 125 || resp.Usage.CacheReadTokens != 100 {
			t.Fatalf("unexpected anthropic usage: %+v", resp.Usage)
		}
	})

	t.Run("openai-responses", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintln(w, `data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_1","delta":"Responses OK"}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":50,"output_tokens":10}}}`)
			fmt.Fprintln(w)
		}))
		defer srv.Close()

		resp, err := StreamLLM(context.Background(), LLMRequest{
			SessionID: "ses_resp",
			Provider: ProviderConfig{
				Protocol: "openai-responses",
				BaseURL:  srv.URL,
				APIKey:   "sk-proj",
				Model:    "gpt-5.2-codex",
			},
			Messages: []Message{{ID: "m1", Role: "user", Parts: []Part{{Type: "text", Text: "ping"}}}},
		}, nil, nil)
		if err != nil {
			t.Fatalf("openai-responses failed: %v", err)
		}
		if len(resp.Parts) != 1 || resp.Parts[0].Text != "Responses OK" || resp.Usage.InputTokens != 50 {
			t.Fatalf("unexpected responses output: %+v", resp)
		}
	})
}

func TestRunnerLoopSnapshotAndRevert(t *testing.T) {
	stateDir := t.TempDir()
	workDir := t.TempDir()
	targetFile := filepath.Join(workDir, "hello.txt")
	if err := os.WriteFile(targetFile, []byte("initial line\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []map[string]any `json:"messages"`
			Tools    []any            `json:"tools"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "text/event-stream")

		// Title request has no tools
		if len(body.Tools) == 0 {
			fmt.Fprintln(w, `data: {"choices":[{"delta":{"content":"Update hello.txt"},"finish_reason":"stop"}]}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: [DONE]`)
			fmt.Fprintln(w)
			return
		}

		step := calls.Add(1)
		if step == 1 {
			fmt.Fprintln(w, `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_edit_1","type":"function","function":{"name":"edit","arguments":"{\"path\":\"hello.txt\",\"oldString\":\"initial line\",\"newString\":\"agent edited line\"}"}}]},"finish_reason":"tool_calls"}]}`)
			fmt.Fprintln(w)
			fmt.Fprintln(w, `data: [DONE]`)
			fmt.Fprintln(w)
			return
		}
		fmt.Fprintln(w, `data: {"choices":[{"delta":{"content":"All done!"},"finish_reason":"stop"}]}`)
		fmt.Fprintln(w)
		fmt.Fprintln(w, `data: [DONE]`)
		fmt.Fprintln(w)
	}))
	defer srv.Close()

	env := &Env{
		StateDir: stateDir,
		Roots:    []Root{{ID: "work", Label: "Work", Path: workDir}},
	}

	sum, err := env.StartRun(RunInput{
		Root:           "work",
		Workdir:        "/",
		Agent:          "build",
		PermissionMode: "auto",
		Text:           "Please update hello.txt",
		Provider: ProviderConfig{
			Protocol: "openai-chat",
			BaseURL:  srv.URL,
			APIKey:   "secret-never-persisted",
			Model:    "gpt-4o",
		},
	})
	if err != nil {
		t.Fatalf("StartRun failed: %v", err)
	}

	// Wait for runLoop to settle
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		sess, running, _, gerr := env.GetSession(sum.ID)
		if gerr == nil && !running && len(sess.Messages) >= 3 {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}

	gotBytes, err := os.ReadFile(targetFile)
	if err != nil || string(gotBytes) != "agent edited line\n" {
		t.Fatalf("expected file edited by agent, got %q (err=%v)", string(gotBytes), err)
	}

	// Ensure API key was NEVER persisted to disk
	persistedBytes, err := os.ReadFile(filepath.Join(stateDir, "ai", "sessions", sum.ID+".json"))
	if err != nil {
		t.Fatalf("persisted session missing: %v", err)
	}
	if strings.Contains(string(persistedBytes), "secret-never-persisted") {
		t.Fatalf("SECURITY FAILURE: API key leaked into session disk file!")
	}

	sess, running, _, err := env.GetSession(sum.ID)
	if err != nil || running {
		t.Fatalf("GetSession failed or still running: running=%v err=%v", running, err)
	}

	// Revert back to the first user message -> restores hello.txt via shadow-git!
	reverted, restoredFiles, err := env.RevertSession(context.Background(), sum.ID, sess.Messages[0].ID, true)
	if err != nil {
		t.Fatalf("RevertSession failed: %v", err)
	}
	if restoredFiles != 1 || len(reverted.Messages) != 0 {
		t.Fatalf("unexpected revert outcome: restored=%d messages=%d", restoredFiles, len(reverted.Messages))
	}
	afterRevert, _ := os.ReadFile(targetFile)
	if string(afterRevert) != "initial line\n" {
		t.Fatalf("expected hello.txt restored to initial content, got %q", string(afterRevert))
	}
}
