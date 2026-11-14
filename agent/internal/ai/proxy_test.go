//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestProviderRouteChoosesSystemAgentAndDirect(t *testing.T) {
	var systemHits, agentHits, directHits atomic.Int32
	server := func(label string, hits *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"id": label}}})
		}))
	}
	sys := server("system-fixture", &systemHits)
	defer sys.Close()
	agent := server("agent-fixture", &agentHits)
	defer agent.Close()
	direct := server("direct-fixture", &directHits)
	defer direct.Close()
	t.Setenv("HTTP_PROXY", sys.URL)
	t.Setenv("HTTPS_PROXY", sys.URL)
	t.Setenv("NO_PROXY", "")
	e := &Env{Proxy: func() map[string]string { return map[string]string{"HTTP_PROXY": sys.URL} }, AgentProxy: func() map[string]string { return map[string]string{"HTTP_PROXY": agent.URL} }}
	for _, mode := range []string{"system", "agent", "direct"} {
		base := "http://models.fixture.invalid/v1"
		if mode == "direct" {
			base = direct.URL + "/v1"
		}
		cfg := ProviderConfig{Protocol: "openai-chat", BaseURL: base, ProxyMode: mode}
		models, err := FetchModels(context.Background(), cfg, e.proxyFor(cfg))
		if err != nil || len(models) != 1 || models[0].ID != mode+"-fixture" {
			t.Fatalf("%s: %+v %v", mode, models, err)
		}
	}
	if systemHits.Load() != 1 || agentHits.Load() != 1 || directHits.Load() != 1 {
		t.Fatal("requests used the wrong route")
	}
	cfg := ProviderConfig{Protocol: "openai-chat", BaseURL: direct.URL + "/v1", ProxyMode: "agent"}
	if _, err := FetchModels(context.Background(), cfg, nil); err == nil {
		t.Fatal("missing agent silently dialed direct")
	}
	if directHits.Load() != 1 {
		t.Fatal("unavailable route made a direct request")
	}
}
