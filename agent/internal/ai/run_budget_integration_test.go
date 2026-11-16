//go:build linux || windows

package ai

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSharedRunBudgetStopsUpstreamAdmissionAndOversizedStream(t *testing.T) {
	var calls atomic.Int32
	var huge atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		calls.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		text := "ok"
		if huge.Load() {
			text = strings.Repeat("x", 5000)
		}
		fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", text)
	}))
	defer server.Close()
	cfg := defaultExtensionConfig()
	cfg.Budget.Steps = 1
	cfg.Budget.OutputBytes = 4096
	meter := newRunMeter(cfg)
	req := LLMRequest{Provider: ProviderConfig{Protocol: "openai-chat", Model: "fixture", BaseURL: server.URL},
		MaxTokens: 32, Messages: []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "prompt"}}}}}
	aux := req
	aux.BudgetAuxiliary = true
	if _, err := streamBudgeted(context.Background(), aux, nil, nil, meter); err != nil {
		t.Fatal(err)
	}
	response, err := streamBudgeted(context.Background(), req, nil, nil, meter)
	if err != nil || !response.Usage.Estimated {
		t.Fatal(response.Usage, err)
	}
	if _, err := streamBudgeted(context.Background(), req, nil, nil, meter); err == nil {
		t.Fatal("step budget bypassed")
	}
	if calls.Load() != 2 {
		t.Fatal("budget rejection still contacted provider")
	}
	huge.Store(true)
	meter = newRunMeter(cfg)
	visible := 0
	if _, err := streamBudgeted(context.Background(), req, nil, func(d LLMDelta) { visible += len(d.Text) }, meter); err == nil {
		t.Fatal("oversized stream accepted")
	}
	if visible > 4096 {
		t.Fatal("oversized delta delivered")
	}
	aux.BudgetAuxiliary = true
	if _, err := streamBudgeted(context.Background(), aux, nil, nil, meter); err == nil {
		t.Fatal("auxiliary call bypassed exhausted output budget")
	}
}
