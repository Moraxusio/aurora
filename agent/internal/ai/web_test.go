//go:build linux

package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTMLToMarkdown(t *testing.T) {
	src := `<html><head><style>p{color:red}</style><script>evil()</script></head><body>
<h1>Title <b>here</b></h1><p>Hello <a href="https://x.dev/a">link</a> and <code>x := 1</code>.</p>
<ul><li>one</li><li>two</li></ul><pre>line1
  line2</pre><!-- hidden --></body></html>`
	md := htmlToMarkdown(src)
	for _, want := range []string{"# Title **here**", "[link](https://x.dev/a)", "`x := 1`", "- one", "- two", "```\nline1\n  line2\n```"} {
		if !strings.Contains(md, want) {
			t.Fatalf("markdown missing %q in:\n%s", want, md)
		}
	}
	for _, bad := range []string{"evil()", "color:red", "hidden", "<b>"} {
		if strings.Contains(md, bad) {
			t.Fatalf("markdown should not contain %q:\n%s", bad, md)
		}
	}
	txt := htmlToText(src)
	if strings.Contains(txt, "<") || !strings.Contains(txt, "Hello link and x := 1.") {
		t.Fatalf("bad text view: %q", txt)
	}
}

func TestParseExaResults(t *testing.T) {
	text := "Title: Go 1.26\nURL: https://go.dev/doc/go1.26\nPublished: 2026-02-10\nHighlights:\nNew things.\n\n---\n\nTitle: N/A\nURL: https://example.com/x\nPublished: N/A\nText:\nBody"
	res := parseExaResults(text)
	if len(res) != 2 || res[0].Title != "Go 1.26" || res[0].Content != "New things." || res[0].Published.IsZero() {
		t.Fatalf("unexpected first result: %+v", res)
	}
	if res[1].Title != "" || res[1].URL != "https://example.com/x" || !res[1].Published.IsZero() {
		t.Fatalf("unexpected second result: %+v", res[1])
	}
	out := formatWebResults(res)
	if !strings.HasPrefix(out, "## [Go 1.26](https://go.dev/doc/go1.26)\nPublished: 2026-02-10T") || !strings.Contains(out, "## [https://example.com/x](https://example.com/x)") {
		t.Fatalf("unexpected formatting:\n%s", out)
	}
	if formatWebResults(nil) != NoSearchResults {
		t.Fatal("empty results must use OpenCode's message")
	}
}

func TestParseMCPBodyJSONAndSSE(t *testing.T) {
	plain := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"A"}]}}`
	sse := "event: message\ndata: " + plain + "\n\n"
	for _, body := range []string{plain, sse} {
		env, err := parseMCPBody(body)
		if err != nil || len(env.Result.Content) != 1 || env.Result.Content[0].Text != "A" {
			t.Fatalf("parse %q: %v %+v", body, err, env)
		}
	}
	if _, err := parseMCPBody("<html>"); err == nil {
		t.Fatal("html must not parse")
	}
}

func webTestContext(t *testing.T) toolContext {
	env := &Env{StateDir: t.TempDir()}
	env.init()
	return toolContext{env: env, session: &Session{ID: "ses_web", Agent: "build", PermissionMode: "auto"}}
}

func TestWebSearchAndFetchTools(t *testing.T) {
	var gotRPC map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/mcp":
			if r.Header.Get("User-Agent") != OpenCodeUserAgent || !strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
				t.Errorf("bad MCP headers: %v", r.Header)
			}
			_ = json.NewDecoder(r.Body).Decode(&gotRPC)
			text := "Title: Result One\nURL: https://one.example/\nHighlights:\nfirst"
			b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "result": map[string]any{"content": []map[string]string{{"type": "text", "text": text}}}})
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "event: message\ndata: %s\n\n", b)
		case "/page":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, "<h2>Docs</h2><p>See <a href=\"/next\">next</a></p>")
		case "/bin":
			w.Header().Set("Content-Type", "application/zip")
			fmt.Fprint(w, "PK")
		case "/redir":
			http.Redirect(w, r, "/page", http.StatusFound)
		}
	}))
	defer srv.Close()
	old := exaMCPEndpoint
	exaMCPEndpoint = srv.URL + "/mcp"
	defer func() { exaMCPEndpoint = old }()

	tc := webTestContext(t)
	allow := func(string, string, map[string]any) error { return nil }

	res := execWebSearch(context.Background(), tc, json.RawMessage(`{"query":"go release"}`), allow)
	if res.IsError || !strings.Contains(res.Output, "## [Result One](https://one.example/)") {
		t.Fatalf("websearch failed: %+v", res)
	}
	params := gotRPC["params"].(map[string]any)
	args := params["arguments"].(map[string]any)
	if gotRPC["method"] != "tools/call" || params["name"] != "web_search_exa" || args["query"] != "go release" || args["numResults"].(float64) != 8 {
		t.Fatalf("wrong Exa MCP request: %v", gotRPC)
	}
	if src, _ := res.Metadata["sources"].([]map[string]string); len(src) != 1 || src[0]["url"] != "https://one.example/" {
		t.Fatalf("sources metadata missing: %v", res.Metadata)
	}

	f := execWebFetch(context.Background(), tc, json.RawMessage(fmt.Sprintf(`{"url":%q}`, srv.URL+"/redir")), allow)
	if f.IsError || !strings.Contains(f.Output, "## Docs") || !strings.Contains(f.Output, "[next](/next)") {
		t.Fatalf("webfetch markdown (through a redirect) failed: %+v", f)
	}
	if b := execWebFetch(context.Background(), tc, json.RawMessage(fmt.Sprintf(`{"url":%q}`, srv.URL+"/bin")), allow); !b.IsError || !strings.Contains(b.Output, "Unsupported fetched file content type: application/zip") {
		t.Fatalf("binary must be refused: %+v", b)
	}
	for _, bad := range []string{"file:///etc/passwd", "ftp://x/y", "https://user:pw@evil.com/"} {
		if r := execWebFetch(context.Background(), tc, json.RawMessage(fmt.Sprintf(`{"url":%q}`, bad)), allow); !r.IsError {
			t.Fatalf("%s must be refused", bad)
		}
	}
}

func TestFetchModelsFallsBackToV1AndExplainsHTML(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"data":[{"id":"b-model"},{"id":"a-model","context_length":64000}]}`)
		default:
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<!doctype html><html>gateway home</html>")
		}
	}))
	defer srv.Close()

	// Base URL typed without /v1: the web page answers, then /v1/models works.
	list, err := FetchModels(context.Background(), ProviderConfig{Protocol: "openai-chat", BaseURL: srv.URL, APIKey: "k"}, nil)
	if err != nil || len(list) != 2 || list[0].ID != "a-model" || list[0].ContextWindow != 64000 {
		t.Fatalf("expected /v1 fallback, got %v %v", list, err)
	}
	// A pasted full endpoint is trimmed back to the API root.
	if list, err = FetchModels(context.Background(), ProviderConfig{Protocol: "openai-chat", BaseURL: srv.URL + "/v1/chat/completions"}, nil); err != nil || len(list) != 2 {
		t.Fatalf("endpoint paste failed: %v %v", list, err)
	}
	// Only the web page: a clear message instead of a JSON parse error.
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "<html>nope</html>") }))
	defer bad.Close()
	_, err = FetchModels(context.Background(), ProviderConfig{Protocol: "openai-chat", BaseURL: bad.URL}, nil)
	if err == nil || !strings.Contains(err.Error(), "Base URL") || strings.Contains(err.Error(), "invalid character") {
		t.Fatalf("unhelpful error: %v", err)
	}
}

func TestHistoryPinRenameSearchExport(t *testing.T) {
	env := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "r", Path: t.TempDir()}}}
	env.init()
	mk := func(id, title, text string, updated int64) {
		env.sessions[id] = &Session{ID: id, Title: title, Root: "r", Workdir: "/", Agent: "build", CreatedAt: 1, UpdatedAt: updated, Messages: []Message{
			{ID: "m_" + id, SessionID: id, Role: "user", Parts: []Part{{Type: "text", Text: text}}},
			{ID: "a_" + id, SessionID: id, Role: "assistant", Parts: []Part{
				{Type: "text", Text: "reply for " + title},
				{Type: "tool-call", ToolCallID: "c1", ToolName: "shell", Input: json.RawMessage(`{"command":"ls"}`)},
				{Type: "tool-result", ToolCallID: "c1", Output: "file.txt"},
			}},
		}}
	}
	mk("s1", "Nginx tuning", "why is nginx returning 502 on the upstream", 100)
	mk("s2", "Redis fix", "redis refuses connections", 300)
	mk("s3", "Old chat", "hello there", 200)

	if l := env.ListSessions(false); l[0].ID != "s2" || l[1].ID != "s3" || l[0].Preview == "" {
		t.Fatalf("expected newest first with a preview: %+v", l)
	}
	pin := true
	if _, err := env.UpdateSessionMeta("s1", nil, &pin); err != nil {
		t.Fatal(err)
	}
	if l := env.ListSessions(false); l[0].ID != "s1" || !l[0].Pinned || l[0].UpdatedAt != 100 {
		t.Fatalf("pinned session must lead and keep its activity time: %+v", l[0])
	}
	newTitle := "  Nginx 502 notes "
	if sum, err := env.UpdateSessionMeta("s1", &newTitle, nil); err != nil || sum.Title != "Nginx 502 notes" {
		t.Fatalf("rename: %v %+v", err, sum)
	}
	blank := "   "
	if _, err := env.UpdateSessionMeta("s1", &blank, nil); err == nil {
		t.Fatal("blank title must be refused")
	}

	hits := env.SearchSessions("NGINX 502", 10)
	if len(hits) != 1 || hits[0].SessionID != "s1" || !strings.Contains(strings.ToLower(hits[0].Snippet), "502") {
		t.Fatalf("search by words across title and text: %+v", hits)
	}
	if len(env.SearchSessions("redis nginx", 10)) != 0 {
		t.Fatal("every word must match in one session")
	}
	if len(env.SearchSessions("中文没有", 10)) != 0 || len(env.SearchSessions("   ", 10)) != 0 {
		t.Fatal("no match / empty query must return nothing")
	}

	name, md, err := env.ExportMarkdown("s2")
	if err != nil || name != "Redis fix.md" || !strings.Contains(md, "# Redis fix") || !strings.Contains(md, "redis refuses connections") || !strings.Contains(md, "<summary>") || !strings.Contains(md, "file.txt") {
		t.Fatalf("export: %v %q\n%s", err, name, md)
	}
}
