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
