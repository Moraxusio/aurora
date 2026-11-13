//go:build linux || windows

package ai

import (
	"aurora3/internal/wire"
	"bytes"
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
)

func TestHistoryStreamsOversizedMessages(t *testing.T) {
	e := &Env{}
	e.init()
	e.sessions["large"] = &Session{ID: "large", Messages: []Message{{ID: "msg", Role: "assistant", Parts: []Part{{Type: "tool-result", Output: strings.Repeat("中文 shell output\n", 100000)}}}}}
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		done <- (svc{e}).opHistory(context.Background(), server, json.RawMessage(`{"id":"large"}`))
	}()
	var response wire.Response
	if err := wire.ReadJSON(client, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK {
		t.Fatal(response)
	}
	var b bytes.Buffer
	frames := 0
	for {
		typ, p, err := wire.ReadFrame(client)
		if err != nil {
			t.Fatal(err)
		}
		if typ == wire.TypeEnd {
			break
		}
		if typ != wire.TypeData {
			t.Fatalf("unexpected type %c", typ)
		}
		b.Write(p)
		frames++
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if frames < 5 {
		t.Fatalf("history not chunked: %d", frames)
	}
	var result struct {
		Session Session `json:"session"`
	}
	if err := json.Unmarshal(b.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Session.Messages[0].Parts[0].Output != e.sessions["large"].Messages[0].Parts[0].Output {
		t.Fatal("history content changed")
	}
}
func TestActivitySnapshotIncludesChildTools(t *testing.T) {
	e := &Env{}
	e.init()
	e.sessions["parent"] = &Session{ID: "parent"}
	e.sessions["child"] = &Session{ID: "child", ParentID: "parent", Title: "检查代码"}
	e.broadcast(StreamEvent{Type: "tool.running", SessionID: "child", ToolCallID: "c", ToolName: "shell", Input: json.RawMessage(`{"command":"test"}`)})
	e.broadcast(StreamEvent{Type: "tool.progress", SessionID: "child", ToolCallID: "c", Delta: "synthetic output"})
	a := e.activitiesFor("parent")
	if len(a) != 1 || a[0].RootSessionID != "parent" || a[0].Output != "synthetic output" || a[0].SessionTitle != "检查代码" {
		t.Fatalf("bad activity: %+v", a)
	}
	e.broadcast(StreamEvent{Type: "tool.done", SessionID: "child", ToolCallID: "c"})
	if len(e.activitiesFor("parent")) != 0 {
		t.Fatal("completed activity retained")
	}
}
func TestModelListShapes(t *testing.T) {
	for _, body := range []string{`{"data":[{"id":"custom","context_window":32000}]}`, `{"models":[{"id":"custom"}]}`, `[{"id":"custom"}]`, `["custom","custom"]`} {
		list, err := parseModelList([]byte(body))
		if err != nil || len(list) != 1 || list[0].ID != "custom" {
			t.Fatalf("%s: %+v %v", body, list, err)
		}
	}
	if _, err := parseModelList([]byte(`{"error":"wrong endpoint"}`)); err == nil {
		t.Fatal("unexpected JSON accepted as empty models")
	}
}
