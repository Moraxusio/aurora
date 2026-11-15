//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func harnessContext(t *testing.T) toolContext {
	t.Helper()
	root := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	e.init()
	s := &Session{ID: "test-session", Agent: "build", PermissionMode: "auto", Root: "work", Workdir: "/"}
	e.sessions[s.ID] = s
	return toolContext{env: e, session: s, rootPath: root, absWorkdir: root, callID: "call"}
}

func fixtureJSON(value any) json.RawMessage {
	b, _ := json.Marshal(value)
	return b
}

func awaitEvent(t *testing.T, events <-chan StreamEvent, kind string) StreamEvent {
	t.Helper()
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	for {
		select {
		case event := <-events:
			if event.Type == kind {
				return event
			}
		case <-timer.C:
			t.Fatalf("timed out waiting for %s", kind)
			return StreamEvent{}
		}
	}
}

func TestHarnessMediaReadRoundTripAllProtocols(t *testing.T) {
	for _, protocol := range []string{"openai-chat", "openai-responses", "anthropic-messages"} {
		t.Run(protocol, func(t *testing.T) {
			tc := harnessContext(t)
			img := image.NewRGBA(image.Rect(0, 0, 2, 2))
			img.Set(0, 0, color.RGBA{R: 255, A: 255})
			var encoded bytes.Buffer
			_ = png.Encode(&encoded, img)
			data := encoded.Bytes()
			pdf := []byte("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n%%EOF")
			_ = os.WriteFile(filepath.Join(tc.rootPath, "chart.png"), data, 0600)
			_ = os.WriteFile(filepath.Join(tc.rootPath, "report.pdf"), pdf, 0600)
			requests := make(chan map[string]any, 8)
			stage := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				_ = json.NewDecoder(r.Body).Decode(&body)
				if r.Header.Get("User-Agent") != OpenCodeUserAgent {
					t.Errorf("compatibility user-agent changed: %s", r.Header.Get("User-Agent"))
				}
				tools, _ := body["tools"].([]any)
				calls := len(tools) > 0 && stage == 0
				if len(tools) > 0 {
					stage++
					requests <- body
				}
				w.Header().Set("Content-Type", "text/event-stream")
				switch protocol {
				case "openai-chat":
					if calls {
						fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": []any{
							map[string]any{"index": 0, "id": "image-call", "type": "function", "function": map[string]any{"name": "read", "arguments": `{"path":"chart.png"}`}},
							map[string]any{"index": 1, "id": "pdf-call", "type": "function", "function": map[string]any{"name": "read", "arguments": `{"path":"report.pdf"}`}},
						}}, "finish_reason": "tool_calls"}}}))+"\n\n")
					} else {
						fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\n")
					}
					fmt.Fprint(w, "data: [DONE]\n\n")
				case "openai-responses":
					if calls {
						for i, file := range []string{"chart.png", "report.pdf"} {
							id := []string{"image-call", "pdf-call"}[i]
							item := map[string]any{"type": "function_call", "id": "fc_" + id, "call_id": id, "name": "read", "arguments": string(fixtureJSON(map[string]string{"path": file}))}
							fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "response.output_item.added", "output_index": i, "item": item}))+"\n\n")
							fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "response.output_item.done", "output_index": i, "item": item}))+"\n\n")
						}
					} else {
						fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\n")
					}
					fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
				case "anthropic-messages":
					fmt.Fprint(w, "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12}}}\n\n")
					if calls {
						for i, file := range []string{"chart.png", "report.pdf"} {
							fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "content_block_start", "index": i, "content_block": map[string]any{
								"type": "tool_use", "id": []string{"image-call", "pdf-call"}[i], "name": "read",
							}}))+"\n\n")
							fmt.Fprint(w, "data: "+string(fixtureJSON(map[string]any{"type": "content_block_delta", "index": i, "delta": map[string]any{
								"type": "input_json_delta", "partial_json": string(fixtureJSON(map[string]string{"path": file})),
							}}))+"\n\n")
						}
						fmt.Fprint(w, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n")
					} else {
						fmt.Fprint(w, "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n")
						fmt.Fprint(w, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n")
					}
					fmt.Fprint(w, "data: {\"type\":\"message_stop\"}\n\n")
				}
			}))
			defer server.Close()
			events := tc.env.subscribe()
			defer tc.env.unsubscribe(events)
			prov := ProviderConfig{BaseURL: server.URL, Protocol: protocol, Model: "fixture", ReasoningEffort: ""}
			sum, err := tc.env.StartRun(RunInput{Root: "work", Workdir: "/", Agent: "plan", Text: "inspect", Provider: prov})
			if err != nil {
				t.Fatal(err)
			}
			awaitEvent(t, events, "step.finish")
			for {
				event := awaitEvent(t, events, "session.status")
				if event.Status == "idle" {
					break
				}
			}
			if len(requests) != 2 {
				t.Fatalf("expected read + media follow-up requests, got %d", len(requests))
			}
			<-requests
			followup := <-requests
			body := string(fixtureJSON(followup))
			for _, b := range [][]byte{data, pdf} {
				if !strings.Contains(body, base64.StdEncoding.EncodeToString(b)) {
					t.Fatalf("actual captured media missing from %s request: %s", protocol, body)
				}
			}
			if protocol == "openai-chat" {
				messages := followup["messages"].([]any)
				if messages[len(messages)-1].(map[string]any)["role"] != "user" ||
					messages[len(messages)-2].(map[string]any)["tool_call_id"] != "pdf-call" ||
					messages[len(messages)-3].(map[string]any)["tool_call_id"] != "image-call" {
					t.Fatal("media split the tool-result batch")
				}
			}
			sess, _, _, _ := tc.env.GetSession(sum.ID)
			var attachment Part
			for _, m := range sess.Messages {
				for _, p := range m.Parts {
					if len(p.Attachments) > 0 && p.Attachments[0].Mime == "image/png" {
						attachment = p.Attachments[0]
					}
				}
			}
			raw, _ := os.ReadFile(filepath.Join(tc.env.sessionsDir(), sum.ID+".json"))
			if attachment.AttachmentID == "" || bytes.Contains(raw, []byte("base64,")) {
				t.Fatal("durable media must use attachment references")
			}
			_ = os.WriteFile(filepath.Join(tc.rootPath, "chart.png"), []byte("changed"), 0600)
			got, err := tc.env.loadAttachment(attachment)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatal("history reread the changed workspace file")
			}
			loaded := &Env{StateDir: tc.env.StateDir}
			reloaded, _, _, err := loaded.GetSession(sum.ID)
			if err != nil {
				t.Fatal(err)
			}
			calls := 0
			disabled, err := materializeAttachments(reloaded.Messages, func(p Part) ([]byte, error) {
				calls++
				return nil, errors.New("disabled media must not load")
			}, ProviderConfig{Capabilities: map[string]bool{"image_input": false, "pdf_input": false}})
			if err != nil || calls != 0 || !strings.Contains(string(fixtureJSON(disabled)), "omitted") {
				t.Fatal("disabled historic media was not explicitly omitted")
			}
		})
	}
}

func TestHarnessCapabilitiesAndArgumentValidationPreventSideEffects(t *testing.T) {
	tc := harnessContext(t)
	path := filepath.Join(tc.rootPath, "file.txt")
	_ = os.WriteFile(path, []byte("keep"), 0600)
	for _, caps := range []map[string]bool{{"tool_calling": false}, {"write": false}} {
		tc.provider.Capabilities = caps
		res := executeTool(context.Background(), tc, "write", fixtureJSON(map[string]string{"path": "file.txt", "content": "replace"}))
		if !res.IsError {
			t.Fatal("disabled tool executed")
		}
	}
	tc.provider.Capabilities = nil
	for _, args := range []string{`{"path":"file.txt"}`, `{"path":"file.txt","content":null}`, `{"path":"file.txt","content":123}`} {
		if res := executeTool(context.Background(), tc, "write", json.RawMessage(args)); !res.IsError {
			t.Fatalf("invalid write accepted: %s", args)
		}
	}
	if got, _ := os.ReadFile(path); string(got) != "keep" {
		t.Fatal("invalid/disabled tool changed the file")
	}
	caps := map[string]bool{"read": true}
	prepared, err := prepareModelOptions(ProviderConfig{Capabilities: caps, ReasoningEffort: "max"})
	caps["read"] = false
	if err != nil || !prepared.allows("read") || prepared.ReasoningEffort != "max" {
		t.Fatal("capability snapshot aliases caller or effort was coerced")
	}
}

func TestHarnessMutationsRecheckApprovalAndCancel(t *testing.T) {
	for _, name := range []string{"write", "edit", "apply_patch"} {
		for _, cancelRun := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/cancel=%t", name, cancelRun), func(t *testing.T) {
				tc := harnessContext(t)
				path := filepath.Join(tc.rootPath, "file.txt")
				_ = os.WriteFile(path, []byte("before\n"), 0600)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				approve := func(string, string, map[string]any) error {
					if cancelRun {
						cancel()
					} else {
						_ = os.WriteFile(path, []byte("user edit\n"), 0600)
					}
					return nil
				}
				var res ToolExecResult
				switch name {
				case "write":
					res = execWriteTool(ctx, tc, json.RawMessage(`{"path":"file.txt","content":"after\n"}`), approve)
				case "edit":
					res = execEditTool(ctx, tc, json.RawMessage(`{"path":"file.txt","oldString":"before","newString":"after"}`), approve)
				case "apply_patch":
					res = execPatchTool(ctx, tc, fixtureJSON(map[string]string{"patch": "*** Begin Patch\n*** Update File: file.txt\n@@\n-before\n+after\n*** End Patch"}), approve)
				}
				want := "user edit\n"
				if cancelRun {
					want = "before\n"
				}
				if got, _ := os.ReadFile(path); !res.IsError || string(got) != want {
					t.Fatalf("stale/cancelled commit: %+v, file=%s", res, got)
				}
			})
		}
	}
}

func TestHarnessPatchTransaction(t *testing.T) {
	tc := harnessContext(t)
	allow := func(string, string, map[string]any) error { return nil }
	run := func(text string, check func(string, string, map[string]any) error) ToolExecResult {
		return execPatchTool(context.Background(), tc, fixtureJSON(map[string]string{"patch": text}), check)
	}
	_ = os.WriteFile(filepath.Join(tc.rootPath, "old.txt"), []byte("first\r\nsecond\r\n"), 0600)
	_ = os.WriteFile(filepath.Join(tc.rootPath, "delete.txt"), []byte("delete\n"), 0600)
	patch := "*** Begin Patch\n*** Update File: old.txt\n*** Move to: moved.txt\n@@\n first\n-second\n+updated\n*** Add File: new.txt\n+created\n*** Delete File: delete.txt\n*** End Patch"
	var resources []string
	res := run(patch, func(action, resource string, _ map[string]any) error {
		resources = append(resources, action+":"+resource)
		return nil
	})
	if res.IsError || len(resources) != 4 {
		t.Fatalf("patch/permissions failed: %+v %v", res, resources)
	}
	if got, _ := os.ReadFile(filepath.Join(tc.rootPath, "moved.txt")); string(got) != "first\r\nupdated\r\n" {
		t.Fatal("move or CRLF preservation failed")
	}
	for _, name := range []string{"old.txt", "delete.txt"} {
		if _, err := os.Stat(filepath.Join(tc.rootPath, name)); !os.IsNotExist(err) {
			t.Fatal("source/delete target remains")
		}
	}
	// Preflight failure leaves every earlier target untouched.
	res = run("*** Begin Patch\n*** Update File: new.txt\n@@\n-created\n+bad\n*** Update File: missing.txt\n@@\n-old\n+new\n*** End Patch", allow)
	if got, _ := os.ReadFile(filepath.Join(tc.rootPath, "new.txt")); !res.IsError || string(got) != "created\n" {
		t.Fatal("partial preflight commit")
	}
	// Commit failure on a child of an existing file rolls back earlier writes.
	res = run("*** Begin Patch\n*** Update File: new.txt\n@@\n-created\n+bad\n*** Add File: moved.txt/child.txt\n+impossible\n*** End Patch", allow)
	if got, _ := os.ReadFile(filepath.Join(tc.rootPath, "new.txt")); !res.IsError || string(got) != "created\n" {
		t.Fatal("failed commit was not restored")
	}
	res = run("*** Begin Patch\n*** Update File: new.txt\n@@\n-created\n+bad\n*** Add File: forbidden.txt\n+blocked\n*** End Patch",
		func(action, resource string, _ map[string]any) error {
			if resource == "forbidden.txt" {
				return errors.New("denied")
			}
			return nil
		})
	if got, _ := os.ReadFile(filepath.Join(tc.rootPath, "new.txt")); !res.IsError || string(got) != "created\n" {
		t.Fatal("permission denial caused a partial commit")
	}
}

func TestHarnessSearchRespectsPerFilePolicyAndOptions(t *testing.T) {
	tc := harnessContext(t)
	for _, file := range []string{"public.go", "private.go", ".hidden.go"} {
		_ = os.WriteFile(filepath.Join(tc.rootPath, file), []byte("Needle[1]\nneedle[1]\n"), 0600)
	}
	tc.session.PermissionRules = []PermissionRule{{Action: "read", Resource: "private.go", Effect: "deny"}}
	res := executeTool(context.Background(), tc, "grep", json.RawMessage(`{"pattern":"needle[1]","literal":true,"caseSensitive":false,"include":"*.{go,ts}","limit":1}`))
	if res.IsError || !strings.Contains(res.Output, "public.go:1:Needle[1]") || strings.Contains(res.Output, "private.go:") || strings.Contains(res.Output, ".hidden.go:") {
		t.Fatalf("search violated options/policy: %+v", res)
	}
	if res := executeTool(context.Background(), tc, "grep", json.RawMessage(`{"pattern":"Needle","path":"private.go"}`)); !res.IsError {
		t.Fatal("direct-file grep bypassed read denial")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if res := execGlobTool(ctx, tc, json.RawMessage(`{"pattern":"**/*"}`)); !res.IsError {
		t.Fatal("cancelled glob reported a successful empty result")
	}
}

func TestHarnessQuestionAnswerSkipCancelAndReconnect(t *testing.T) {
	for _, action := range []string{"answer", "skip", "stop"} {
		t.Run(action, func(t *testing.T) {
			tc := harnessContext(t)
			events := tc.env.subscribe()
			defer tc.env.unsubscribe(events)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan ToolExecResult, 1)
			go func() {
				done <- executeTool(ctx, tc, "question", json.RawMessage(`{"questions":[{"question":"Choose","options":[{"label":"A"},{"label":"B"}]}]}`))
			}()
			event := awaitEvent(t, events, "question.ask")
			if event.Question == nil {
				t.Fatal("missing question")
			}
			// A new client fetch recovers the same pending question.
			value, err := (svc{tc.env}).opQuestion(ctx, fixtureJSON(map[string]string{"session_id": tc.session.ID}))
			if err != nil || !strings.Contains(string(fixtureJSON(value)), event.Question.ID) {
				t.Fatal("pending question was not recoverable")
			}
			switch action {
			case "stop":
				cancel()
			default:
				args := map[string]any{"session_id": tc.session.ID, "id": event.Question.ID}
				if action == "skip" {
					args["cancel"] = true
				} else {
					args["answers"] = [][]string{{"custom answer"}}
				}
				if _, err := (svc{tc.env}).opQuestion(ctx, fixtureJSON(args)); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case result := <-done:
				if action == "answer" && (result.IsError || !strings.Contains(result.Output, "custom answer")) ||
					action == "skip" && (result.IsError || !strings.Contains(result.Output, "skipped")) ||
					action == "stop" && !result.IsError {
					t.Fatalf("wrong question result: %+v", result)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("question stayed blocked")
			}
			value, _ = (svc{tc.env}).opQuestion(context.Background(), fixtureJSON(map[string]string{"session_id": tc.session.ID}))
			if value.(map[string]any)["question"] != nil {
				t.Fatal("completed question is still pending")
			}
		})
	}
}

func TestHarnessJournalRecoveryPreservesKnownResults(t *testing.T) {
	tc := harnessContext(t)
	m := Message{ID: "step", SessionID: tc.session.ID, Role: "assistant", Finish: "tool-running", Parts: []Part{
		{Type: "tool-call", ToolName: "write", ToolCallID: "known"},
		{Type: "tool-call", ToolName: "shell", ToolCallID: "unknown"},
		{Type: "tool-result", ToolName: "write", ToolCallID: "known", Output: "saved"},
	}}
	if err := tc.env.checkpointStep(m); err != nil {
		t.Fatal(err)
	}
	loaded := &Env{StateDir: tc.env.StateDir}
	s, _, _, err := loaded.GetSession(tc.session.ID)
	if err != nil || len(s.Messages) != 1 || len(s.Messages[0].Parts) != 4 || s.Messages[0].Finish != "aborted" {
		t.Fatalf("journal recovery failed: %+v %v", s, err)
	}
	p := s.Messages[0].Parts[3]
	if p.ToolCallID != "unknown" || !p.IsError || !strings.Contains(p.Output, "NOT automatically re-executed") {
		t.Fatalf("recovery pretended to know the outcome: %+v", p)
	}
	recoverInterruptedTools(&s)
	if len(s.Messages[0].Parts) != 4 {
		t.Fatal("recovery duplicated results")
	}
	s.Messages = append(s.Messages, Message{ID: "later", Role: "assistant", Finish: "tool-running",
		Parts: []Part{{Type: "tool-call", ToolCallID: "known", ToolName: "write"}}})
	recoverInterruptedTools(&s)
	if len(s.Messages[1].Parts) != 2 || !s.Messages[1].Parts[1].IsError {
		t.Fatal("a reused call ID incorrectly borrowed an earlier turn's result")
	}
}

func TestHarnessReasoningWireValuesAndDisabledTools(t *testing.T) {
	for _, test := range []struct {
		protocol, mode, effort string
		budget                 int
		want                   string
	}{
		{"openai-chat", "", "max", 0, `"reasoning_effort":"max"`},
		{"openai-responses", "", "ultra", 0, `"effort":"ultra"`},
		{"anthropic-messages", "anthropic-adaptive", "max", 0, `"effort":"max"`},
		{"anthropic-messages", "anthropic-budget", "custom", 8192, `"budget_tokens":8192`},
		{"openai-chat", "disabled", "max", 0, ""},
		{"anthropic-messages", "", "unmapped", 0, "error"},
	} {
		t.Run(test.protocol+"/"+test.mode+"/"+test.effort, func(t *testing.T) {
			requests := make(chan map[string]any, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				_ = json.NewDecoder(r.Body).Decode(&body)
				requests <- body
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}],\"type\":\"message_stop\"}\n\ndata: [DONE]\n\n")
			}))
			defer server.Close()
			_, err := StreamLLM(context.Background(), LLMRequest{
				Provider: ProviderConfig{Protocol: test.protocol, BaseURL: server.URL, Model: "fixture",
					ReasoningMode: test.mode, ReasoningEffort: test.effort, ThinkingBudget: test.budget,
					Capabilities: map[string]bool{"tool_calling": false}},
				Tools:    ToolDefinitions("build", 0),
				Messages: []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "hello"}}}},
			}, nil, func(LLMDelta) {})
			if test.want == "error" {
				if err == nil || len(requests) > 0 {
					t.Fatal("unknown Anthropic effort silently fell back")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			body := <-requests
			if tools, ok := body["tools"].([]any); ok && len(tools) > 0 {
				t.Fatal("disabled tools were declared")
			}
			if test.want != "" && !strings.Contains(string(fixtureJSON(body)), test.want) {
				t.Fatalf("custom effort/budget was changed: %s", fixtureJSON(body))
			}
			if test.mode == "disabled" && body["reasoning_effort"] != nil {
				t.Fatal("disabled reasoning parameter sent")
			}
		})
	}
}

func TestHarnessJournalFailurePreventsToolExecution(t *testing.T) {
	tc := harnessContext(t)
	entered, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		tools, _ := body["tools"].([]any)
		if len(tools) == 0 {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"title\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
			return
		}
		close(entered)
		<-release
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"write\",\"type\":\"function\",\"function\":{\"name\":\"write\",\"arguments\":\"{\\\"path\\\":\\\"should-not-exist\\\",\\\"content\\\":\\\"bad\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n")
	}))
	defer server.Close()
	events := tc.env.subscribe()
	defer tc.env.unsubscribe(events)
	sum, err := tc.env.StartRun(RunInput{Root: "work", Workdir: "/", Agent: "build", PermissionMode: "auto",
		Text: "write", Provider: ProviderConfig{Protocol: "openai-chat", BaseURL: server.URL, Model: "fixture"}})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("model not called")
	}
	target := filepath.Join(tc.env.sessionsDir(), sum.ID+".json")
	_ = os.Remove(target)
	_ = os.Mkdir(target, 0700)
	close(release)
	event := awaitEvent(t, events, "session.error")
	if !strings.Contains(event.Error, "未执行工具") {
		t.Fatal(event.Error)
	}
	awaitEvent(t, events, "session.status")
	if _, err := os.Stat(filepath.Join(tc.rootPath, "should-not-exist")); !os.IsNotExist(err) {
		t.Fatal("tool executed without durable intent")
	}
}
