//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestBudgetZeroSurvivesProjectRoundTripAndMissingUsesDefaults(t *testing.T) {
	work := t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"budget":{"tokens":0}}`)
	cfg, _, err := loadExtensionConfig(work)
	if err != nil || cfg.Budget.Tokens != 0 || cfg.Budget.Steps != 60 {
		t.Fatal(cfg, err)
	}
	cfg.Budget = RunBudget{}
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	_, err = (svc{e}).opExtensions(context.Background(), fixtureJSON(map[string]any{"root": "work", "workdir": "/", "config": cfg}))
	if err != nil {
		t.Fatal(err)
	}
	got, _, err := loadExtensionConfig(e.Roots[0].Path)
	if err != nil || got.Budget != (RunBudget{}) {
		t.Fatal(got, err)
	}
	meter := newRunMeter(got)
	if !meter.deadline.IsZero() {
		t.Fatal("unlimited time acquired a deadline")
	}
	for i := 0; i < 65; i++ {
		req := LLMRequest{Provider: ProviderConfig{Model: "test"}, MaxTokens: 100}
		finish, err := meter.reserve(&req)
		if err != nil {
			t.Fatal(i, err)
		}
		finish(&LLMResponse{Usage: Usage{InputTokens: 2000000, OutputTokens: 100}}, false)
	}
	if meter.snapshot().Tokens <= 2000000 {
		t.Fatal("unlimited run was capped")
	}
}

func TestBudgetFailureUsesObservedUsageAndExplainsNextInput(t *testing.T) {
	cfg := defaultExtensionConfig()
	cfg.Budget.Tokens = 1000
	m := newRunMeter(cfg)
	req := LLMRequest{Provider: ProviderConfig{Model: "test"}, MaxTokens: 900}
	finish, err := m.reserve(&req)
	if err != nil {
		t.Fatal(err)
	}
	failed := LLMResponse{}
	finish(&failed, true)
	finish(&failed, true) // settlement is idempotent
	if m.snapshot().Tokens != 0 || m.snapshot().Reserved != 0 {
		t.Fatal(m.snapshot())
	}
	req.Messages = []Message{{Parts: []Part{{Type: "text", Text: strings.Repeat("input", 2000)}}}}
	_, err = m.reserve(&req)
	var budget *budgetError
	if !errors.As(err, &budget) || budget.kind != "tokens" || !strings.Contains(err.Error(), "下一步输入") {
		t.Fatal(err)
	}
	state := m.snapshot()
	if state.BlockedBy != "tokens" || state.NextInput <= state.Limits.Tokens || !state.Estimated {
		t.Fatal(state)
	}
	cfg.Budget.Tokens = 0
	cfg.Budget.Cost = 0.0000001
	cfg.Prices["test"] = ModelPrice{Output: 100}
	_, err = newRunMeter(cfg).reserve(&LLMRequest{Provider: ProviderConfig{Model: "test"}})
	if !errors.As(err, &budget) || budget.kind != "cost" {
		t.Fatal(err)
	}
}

func TestBudgetStoppedRunPersistsProviderAndCanContinueWithNewLimits(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"continued\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))
	}))
	defer server.Close()
	work, state := t.TempDir(), t.TempDir()
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"budget":{"tokens":1}}`)
	e := &Env{StateDir: state, Roots: []Root{{ID: "work", Path: work}}}
	events := e.subscribe()
	defer e.unsubscribe(events)
	input := RunInput{Root: "work", Workdir: "/", Text: "hello", Provider: ProviderConfig{
		ID: "connection", Name: "My gateway", Model: "fixture", Protocol: "openai-chat", BaseURL: server.URL, APIKey: "secret-fixture"}}
	waitIdle := func(id string) {
		t.Helper()
		timer := time.NewTimer(5 * time.Second)
		defer timer.Stop()
		for {
			select {
			case ev := <-events:
				if ev.SessionID == id && ev.Type == "session.status" && ev.Status == "idle" {
					return
				}
			case <-timer.C:
				t.Fatal("run did not finish")
			}
		}
	}
	sum, err := e.StartRun(input)
	if err != nil {
		t.Fatal(err)
	}
	waitIdle(sum.ID)
	fresh := &Env{StateDir: state, Roots: e.Roots}
	session, _, _, err := fresh.GetSession(sum.ID)
	if err != nil {
		t.Fatal(err)
	}
	last := session.Messages[len(session.Messages)-1]
	if calls.Load() != 0 || last.ErrorCode != "budget.tokens" || last.Runtime == nil ||
		last.Runtime.ProviderID != "connection" || last.Budget == nil || last.Budget.NextInput <= 1 {
		t.Fatal(last, calls.Load())
	}
	data, _ := json.Marshal(session)
	if strings.Contains(string(data), "secret-fixture") {
		t.Fatal("credential leaked")
	}
	extensionFile(t, work, extensionConfigPath, `{"version":1,"autoTitle":false,"budget":{"tokens":0}}`)
	input.SessionID, input.Text = sum.ID, "continue"
	_, err = e.StartRun(input)
	if err != nil {
		t.Fatal(err)
	}
	waitIdle(sum.ID)
	session, _, _, err = e.GetSession(sum.ID)
	if err != nil || calls.Load() != 1 || session.Budget.ID == last.Budget.ID ||
		session.Budget.Limits.Tokens != 0 || session.Budget.Source != "project" {
		t.Fatal(session.Budget, calls.Load(), err)
	}
}

func TestBudgetDeadlineIsStructured(t *testing.T) {
	meter := newRunMeter(defaultExtensionConfig())
	meter.deadline = time.Now().Add(-time.Second)
	_, err := streamBudgeted(context.Background(), LLMRequest{}, nil, nil, meter)
	var limit *budgetError
	if !errors.As(err, &limit) || limit.kind != "seconds" {
		t.Fatal(err)
	}
}
