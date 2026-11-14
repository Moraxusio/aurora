package ai

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestWindowsAIShellInheritsProxyAndStreams(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:12344")
	e := &Env{}
	e.init()
	sub := e.subscribe()
	defer e.unsubscribe(sub)
	tc := toolContext{env: e, session: &Session{ID: "fixture", Agent: "build", PermissionMode: "auto"}, provider: ProviderConfig{UseProxy: true}, absWorkdir: t.TempDir(), callID: "shell-fixture"}
	e.Proxy = func() map[string]string { return map[string]string{"HTTP_PROXY": "http://127.0.0.1:12345"} }
	res := execShellTool(context.Background(), tc, json.RawMessage(`{"command":"Write-Output $env:HTTP_PROXY; Start-Sleep -Milliseconds 200; Write-Output 'fixture-done'"}`), func(string, string, map[string]any) error { return nil })
	if res.IsError || !strings.Contains(res.Output, "http://127.0.0.1:12345") || !strings.Contains(res.Output, "fixture-done") {
		t.Fatalf("shell result: %+v", res)
	}
	select {
	case ev := <-sub:
		if ev.Type != "tool.progress" || ev.ToolCallID != "shell-fixture" {
			t.Fatal(ev.Type)
		}
	default:
		t.Fatal("no live shell output")
	}
	meta := toolRuntimeMetadata("shell", tc.provider, e.Proxy)
	if meta["proxy_mode"] != "agent" {
		t.Fatal(meta)
	}
}

func TestWindowsAIShellExplicitRoutes(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:18101")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:18102")
	t.Setenv("ALL_PROXY", "socks5://127.0.0.1:18103")
	t.Setenv("NO_PROXY", "system.fixture")
	e := &Env{AgentProxy: func() map[string]string { return map[string]string{"HTTP_PROXY": "http://127.0.0.1:18104"} }}
	e.init()
	for _, mode := range []string{"system", "agent", "direct"} {
		tc := toolContext{env: e, session: &Session{ID: "route-fixture", Agent: "build", PermissionMode: "auto"}, provider: ProviderConfig{ProxyMode: mode}, absWorkdir: t.TempDir()}
		res := execShellTool(context.Background(), tc, json.RawMessage(`{"command":"[Console]::WriteLine('ROUTE=' + $env:HTTP_PROXY + '|' + $env:HTTPS_PROXY + '|' + $env:ALL_PROXY + '|' + $env:NO_PROXY)"}`), func(string, string, map[string]any) error { return nil })
		want := map[string]string{"system": "ROUTE=http://127.0.0.1:18101|http://127.0.0.1:18102|socks5://127.0.0.1:18103|system.fixture", "agent": "ROUTE=http://127.0.0.1:18104|||", "direct": "ROUTE=|||"}[mode]
		if res.IsError || !strings.Contains(res.Output, want) {
			t.Fatalf("%s shell chose wrong route: %+v", mode, res)
		}
	}
	e.AgentProxy = func() map[string]string { return nil }
	tc := toolContext{env: e, session: &Session{ID: "missing-fixture"}, provider: ProviderConfig{ProxyMode: "agent"}, absWorkdir: t.TempDir()}
	res := execShellTool(context.Background(), tc, json.RawMessage(`{"command":"Write-Output 'MUST-NOT-RUN'"}`), func(string, string, map[string]any) error { return nil })
	if !res.IsError || strings.Contains(res.Output, "MUST-NOT-RUN") {
		t.Fatal("missing node executed the shell")
	}
}
