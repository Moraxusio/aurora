package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func fixtureResponse(method string) any {
	switch method {
	case "initialize":
		return map[string]any{"protocolVersion": "2025-03-26", "serverInfo": map[string]string{"name": "fixture"}, "capabilities": map[string]any{"tools": map[string]any{}}}
	case "tools/list":
		return map[string]any{"tools": []any{map[string]any{"name": "echo", "description": "Echo", "inputSchema": map[string]any{"type": "object"}}}}
	default:
		return map[string]any{"content": []any{map[string]string{"type": "text", "text": "ok"}}}
	}
}
func TestMCPChild(t *testing.T) {
	if os.Getenv("AURORA_MCP_HELPER") != "1" {
		return
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request struct {
			ID     any    `json:"id"`
			Method string `json:"method"`
		}
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			os.Exit(2)
		}
		if request.ID == nil {
			continue
		}
		if request.Method == "blocked" {
			for {
				time.Sleep(time.Hour)
			}
		}
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": fixtureResponse(request.Method)})
		fmt.Println(string(data))
	}
	os.Exit(0)
}
func TestMCPStdioCatalogAndCancellationReclaimsProcess(t *testing.T) {
	c, err := Connect(context.Background(), Config{ID: "fixture", Command: []string{os.Args[0], "-test.run=TestMCPChild"}, Env: map[string]string{"AURORA_MCP_HELPER": "1"}}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	cat, err := c.Catalog(context.Background())
	if err != nil || len(cat.Tools) != 1 || cat.Tools[0].Name != "echo" {
		t.Fatal(cat, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := c.Call(ctx, "blocked", map[string]any{}); err == nil {
		t.Fatal("blocked tool was not cancelled")
	}
	done := make(chan struct{})
	go func() { c.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("MCP process tree leaked")
	}
	if len(slots) != 0 {
		t.Fatal("MCP lease leaked")
	}
}
func TestMCPStreamableHTTPHeadersSessionAndSSE(t *testing.T) {
	deleted := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "opencode/stable/1.4.0/opencode" || r.Header.Get("originator") != "opencode" || r.Header.Get("x-opencode-client") != "cli" {
			t.Error("compatibility identity changed")
		}
		if r.Method == http.MethodDelete {
			deleted = true
			w.WriteHeader(204)
			return
		}
		var req struct {
			ID     any    `json:"id"`
			Method string `json:"method"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
			return
		}
		if req.Method != "initialize" && r.Header.Get("Mcp-Session-Id") != "session" {
			t.Error("session not propagated")
		}
		w.Header().Set("Mcp-Session-Id", "session")
		if req.ID == nil {
			w.WriteHeader(202)
			return
		}
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": fixtureResponse(req.Method)})
		if req.Method == "tools/list" {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "event: message\ndata: %s\n\n", data)
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.Write(data)
		}
	}))
	defer server.Close()
	c, err := Connect(context.Background(), Config{ID: "http", URL: server.URL}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cat, err := c.Catalog(context.Background())
	if err != nil || len(cat.Tools) != 1 {
		t.Fatal(cat, err)
	}
	c.Close()
	if !deleted {
		t.Fatal("HTTP session not released")
	}
}
func TestMCPRejectsOversizedRepliesAndRepeatedPagination(t *testing.T) {
	for _, oversized := range []bool{false, true} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == "DELETE" {
				return
			}
			data, _ := io.ReadAll(r.Body)
			var req struct {
				ID     any    `json:"id"`
				Method string `json:"method"`
			}
			json.Unmarshal(data, &req)
			if req.ID == nil {
				w.WriteHeader(202)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			if oversized && req.Method == "tools/list" {
				fmt.Fprint(w, strings.Repeat("x", maxMessage+1))
				return
			}
			result := fixtureResponse(req.Method)
			if req.Method == "tools/list" {
				result = map[string]any{"tools": []any{}, "nextCursor": "same"}
			}
			json.NewEncoder(w).Encode(map[string]any{"id": req.ID, "result": result})
		}))
		c, err := Connect(context.Background(), Config{ID: "fixture", URL: server.URL}, t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.Catalog(context.Background()); err == nil {
			t.Fatal("unbounded MCP response accepted")
		}
		c.Close()
		server.Close()
	}
}
