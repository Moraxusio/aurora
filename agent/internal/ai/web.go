//go:build linux

package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Web tools ported from OpenCode (packages/core/src/tool/plugin/webfetch.ts,
// websearch.ts and plugin/websearch/exa.ts + mcp.ts): same tool names, same
// input schemas, the same Exa MCP endpoint and result format.

const (
	webMaxBytes       = 5 * 1024 * 1024
	webDefaultTimeout = 30
	webMaxTimeout     = 120
	webMaxRedirects   = 10
	webFetchUA        = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OpenCode-User/1.0; +https://opencode.ai"
	exaMaxResponse    = 256 * 1024

	// NoSearchResults is OpenCode's text for an empty result list.
	NoSearchResults = "No search results found. Please try a different query."
)

// exaMCPEndpoint is a variable so tests can point it at a local server.
var exaMCPEndpoint = "https://mcp.exa.ai/mcp"

var webFetchToolDef = ToolDef{
	Name: "webfetch",
	Description: `Fetch content from an HTTP or HTTPS URL and return it as text, markdown, or HTML. Markdown is the default.

Use a more targeted tool when one is available. This tool is read-only. Large text results may be replaced with a preview while the complete output is retained in managed storage.`,
	Parameters: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"url": map[string]any{"type": "string", "description": "The HTTP or HTTPS URL to fetch content from"},
			"format": map[string]any{
				"type":        "string",
				"enum":        []string{"text", "markdown", "html"},
				"description": "The format to return the content in. Defaults to markdown.",
			},
			"timeout": map[string]any{"type": "number", "description": fmt.Sprintf("Optional timeout in seconds (maximum: %d)", webMaxTimeout)},
		},
		"required": []string{"url"},
	},
}

var webSearchToolDef = ToolDef{
	Name: "websearch",
	Description: fmt.Sprintf(`Search the web using the user's selected search integration. Use this for current information beyond knowledge cutoff.

The current year is %d. Use this year when searching for recent information or current events.`, time.Now().Year()),
	Parameters: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"query": map[string]any{"type": "string", "description": "Websearch query"},
		},
		"required": []string{"query"},
	},
}

func checkWebURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %v", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, errors.New("URL must use http:// or https://")
	}
	if u.User != nil {
		return nil, errors.New("URL must not include credentials")
	}
	if u.Host == "" {
		return nil, errors.New("URL has no host")
	}
	return u, nil
}

func webAccept(format string) string {
	switch format {
	case "text":
		return "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1"
	case "html":
		return "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1"
	default:
		return "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1"
	}
}

func isTextualMime(m string) bool {
	m = strings.ToLower(strings.TrimSpace(m))
	if m == "" || strings.HasPrefix(m, "text/") {
		return true
	}
	if strings.HasSuffix(m, "+json") || strings.HasSuffix(m, "+xml") {
		return true
	}
	switch m {
	case "application/json", "application/xml", "application/javascript", "application/ecmascript",
		"application/x-javascript", "application/yaml", "application/x-yaml", "application/toml",
		"application/xhtml+xml", "application/x-sh", "application/sql", "application/graphql",
		"application/x-www-form-urlencoded", "application/ld+json":
		return true
	}
	return false
}

func fetchWeb(ctx context.Context, tc toolContext, target, format string) ([]byte, string, error) {
	client := newHTTPClient(tc.provider.UseProxy, tc.env.Proxy)
	// Redirects are followed here (not silently by the transport) so every hop
	// is validated like the first URL, as OpenCode does.
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= webMaxRedirects {
			return fmt.Errorf("Too many redirects (more than %d)", webMaxRedirects)
		}
		_, err := checkWebURL(req.URL.String())
		return err
	}
	do := func(ua string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", ua)
		req.Header.Set("Accept", webAccept(format))
		req.Header.Set("Accept-Language", "en-US,en;q=0.9")
		return client.Do(req)
	}
	res, err := do(webFetchUA)
	if err == nil && res.StatusCode == http.StatusForbidden && res.Header.Get("cf-mitigated") == "challenge" {
		_ = res.Body.Close()
		res, err = do("opencode")
	}
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, "", errors.New("Request timed out")
		}
		return nil, "", err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, "", fmt.Errorf("HTTP %d %s", res.StatusCode, http.StatusText(res.StatusCode))
	}
	ct := res.Header.Get("Content-Type")
	mime := strings.ToLower(strings.TrimSpace(strings.SplitN(ct, ";", 2)[0]))
	if strings.HasPrefix(mime, "image/") && mime != "image/svg+xml" {
		return nil, "", fmt.Errorf("Unsupported fetched image content type: %s", mime)
	}
	if !isTextualMime(mime) && mime != "image/svg+xml" {
		return nil, "", fmt.Errorf("Unsupported fetched file content type: %s", mime)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, webMaxBytes+1))
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, "", errors.New("Request timed out")
		}
		return nil, "", err
	}
	if len(data) > webMaxBytes {
		return nil, "", fmt.Errorf("Response too large (exceeds %d byte limit)", webMaxBytes)
	}
	return data, ct, nil
}

func execWebFetch(ctx context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		URL     string  `json:"url"`
		Format  string  `json:"format"`
		Timeout float64 `json:"timeout"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid webfetch arguments: " + err.Error(), IsError: true}
	}
	target := strings.SplitN(strings.TrimSpace(in.URL), "#", 2)[0]
	if _, err := checkWebURL(target); err != nil {
		return ToolExecResult{Output: fmt.Sprintf("Unable to fetch %s: %v", in.URL, err), IsError: true}
	}
	format := in.Format
	switch format {
	case "text", "markdown", "html":
	case "":
		format = "markdown"
	default:
		return ToolExecResult{Output: "format must be one of text, markdown, html", IsError: true}
	}
	secs := in.Timeout
	if secs <= 0 {
		secs = webDefaultTimeout
	}
	if secs > webMaxTimeout {
		secs = webMaxTimeout
	}
	if err := checkPerm("webfetch", target, map[string]any{"url": target, "format": format}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	cctx, cancel := context.WithTimeout(ctx, time.Duration(secs*float64(time.Second)))
	defer cancel()
	body, ct, err := fetchWeb(cctx, tc, target, format)
	if err != nil {
		return ToolExecResult{Output: fmt.Sprintf("Unable to fetch %s: %v", in.URL, err), IsError: true}
	}
	content := string(body)
	if strings.Contains(strings.ToLower(ct), "text/html") {
		switch format {
		case "markdown":
			content = htmlToMarkdown(content)
		case "text":
			content = htmlToText(content)
		}
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.webfetch", map[string]any{"session": tc.session.ID, "url": target})
	}
	return ToolExecResult{Output: content, Metadata: map[string]any{"contentType": ct, "url": target, "format": format}}
}

// ---- HTML to text / markdown (stdlib only) ----

var (
	reHTMLComment = regexp.MustCompile(`(?s)<!--.*?-->`)
	reTag         = regexp.MustCompile(`(?s)<[^>]*>`)
	reBlankLines  = regexp.MustCompile(`\n{3,}`)
	reSpaces      = regexp.MustCompile(`[ \t\f\r]+`)
	reSkipTags    = func() []*regexp.Regexp {
		var out []*regexp.Regexp
		for _, t := range []string{"script", "style", "noscript", "iframe", "object", "embed", "svg", "template"} {
			out = append(out, regexp.MustCompile(`(?is)<`+t+`\b[^>]*>.*?</`+t+`\s*>`))
		}
		return out
	}()
	reHeadings = func() [6]*regexp.Regexp {
		var out [6]*regexp.Regexp
		for i := 1; i <= 6; i++ {
			out[i-1] = regexp.MustCompile(fmt.Sprintf(`(?is)<h%d\b[^>]*>(.*?)</h%d\s*>`, i, i))
		}
		return out
	}()
	rePre        = regexp.MustCompile(`(?is)<pre\b[^>]*>(.*?)</pre\s*>`)
	reAnchor     = regexp.MustCompile(`(?is)<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>(.*?)</a\s*>`)
	reStrong     = regexp.MustCompile(`(?is)<(?:strong|b)\b[^>]*>(.*?)</(?:strong|b)\s*>`)
	reEm         = regexp.MustCompile(`(?is)<(?:em|i)\b[^>]*>(.*?)</(?:em|i)\s*>`)
	reCodeInline = regexp.MustCompile(`(?is)<code\b[^>]*>(.*?)</code\s*>`)
	reLi         = regexp.MustCompile(`(?i)<li\b[^>]*>`)
	reBr         = regexp.MustCompile(`(?i)<br\s*/?>`)
	reBlockClose = regexp.MustCompile(`(?i)</(?:p|div|section|article|header|footer|ul|ol|table|tr|blockquote|figure|main|nav|aside)\s*>`)
)

func stripSkipped(src string) string {
	s := reHTMLComment.ReplaceAllString(src, "")
	for _, re := range reSkipTags {
		s = re.ReplaceAllString(s, "")
	}
	return s
}

func stripTags(s string) string { return reTag.ReplaceAllString(s, "") }

func normalizeLines(s string, fenced map[string]string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSpace(reSpaces.ReplaceAllString(l, " "))
	}
	out := reBlankLines.ReplaceAllString(strings.Join(lines, "\n"), "\n\n")
	for token, code := range fenced {
		out = strings.ReplaceAll(out, token, code)
	}
	return strings.TrimSpace(out)
}

func htmlToText(src string) string {
	s := stripSkipped(src)
	s = reBr.ReplaceAllString(s, "\n")
	s = reLi.ReplaceAllString(s, "\n")
	s = reBlockClose.ReplaceAllString(s, "\n")
	for _, re := range reHeadings {
		s = re.ReplaceAllString(s, "\n$1\n")
	}
	return normalizeLines(html.UnescapeString(stripTags(s)), nil)
}

func htmlToMarkdown(src string) string {
	s := stripSkipped(src)
	// Code blocks are set aside so later whitespace/tag rules cannot touch them.
	fenced := map[string]string{}
	s = rePre.ReplaceAllStringFunc(s, func(m string) string {
		inner := rePre.FindStringSubmatch(m)[1]
		code := strings.Trim(html.UnescapeString(stripTags(inner)), "\n")
		token := fmt.Sprintf("\x00CODE%d\x00", len(fenced))
		fenced[token] = "```\n" + code + "\n```"
		return "\n\n" + token + "\n\n"
	})
	s = reAnchor.ReplaceAllStringFunc(s, func(m string) string {
		g := reAnchor.FindStringSubmatch(m)
		href := g[1]
		if href == "" {
			href = g[2]
		}
		text := strings.TrimSpace(stripTags(g[3]))
		if text == "" {
			text = href
		}
		if href == "" || strings.HasPrefix(href, "#") || strings.HasPrefix(strings.ToLower(href), "javascript:") {
			return text
		}
		return "[" + text + "](" + html.UnescapeString(href) + ")"
	})
	s = reStrong.ReplaceAllString(s, "**$1**")
	s = reEm.ReplaceAllString(s, "*$1*")
	s = reCodeInline.ReplaceAllString(s, "`$1`")
	for i, re := range reHeadings {
		prefix := strings.Repeat("#", i+1) + " "
		s = re.ReplaceAllStringFunc(s, func(m string) string {
			inner := strings.TrimSpace(stripTags(re.FindStringSubmatch(m)[1]))
			return "\n\n" + prefix + strings.Join(strings.Fields(inner), " ") + "\n\n"
		})
	}
	s = reLi.ReplaceAllString(s, "\n- ")
	s = reBr.ReplaceAllString(s, "\n")
	s = reBlockClose.ReplaceAllString(s, "\n\n")
	return normalizeLines(html.UnescapeString(stripTags(s)), fenced)
}

// ---- websearch (Exa MCP, as OpenCode's exa provider) ----

type webResult struct {
	URL       string
	Title     string
	Content   string
	Published time.Time
}

var (
	reExaURL       = regexp.MustCompile(`(?m)^URL:\s*(.+)$`)
	reExaTitle     = regexp.MustCompile(`(?m)^Title:\s*(.+)$`)
	reExaPublished = regexp.MustCompile(`(?m)^Published:\s*(.+)$`)
	reExaContent   = regexp.MustCompile(`(?m)^(?:Highlights|Text):\s*\n?([\s\S]*)$`)
)

func parseExaResults(text string) []webResult {
	var out []webResult
	for _, block := range strings.Split(text, "\n\n---\n\n") {
		m := reExaURL.FindStringSubmatch(block)
		if m == nil {
			continue
		}
		r := webResult{URL: strings.TrimSpace(m[1])}
		if t := reExaTitle.FindStringSubmatch(block); t != nil {
			if title := strings.TrimSpace(t[1]); title != "N/A" {
				r.Title = title
			}
		}
		if p := reExaPublished.FindStringSubmatch(block); p != nil {
			pub := strings.TrimSpace(p[1])
			for _, layout := range []string{time.RFC3339, "2006-01-02", "Jan 2, 2006", "January 2, 2006"} {
				if tm, err := time.Parse(layout, pub); err == nil {
					r.Published = tm
					break
				}
			}
		}
		if c := reExaContent.FindStringSubmatch(block); c != nil {
			r.Content = strings.TrimSpace(c[1])
		}
		out = append(out, r)
	}
	return out
}

type mcpEnvelope struct {
	Result struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"result"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// parseMCPBody accepts a plain JSON-RPC reply or an SSE stream of `data:` lines.
func parseMCPBody(body string) (*mcpEnvelope, error) {
	try := func(payload string) *mcpEnvelope {
		p := strings.TrimSpace(payload)
		if !strings.HasPrefix(p, "{") {
			return nil
		}
		var env mcpEnvelope
		if json.Unmarshal([]byte(p), &env) != nil {
			return nil
		}
		return &env
	}
	if env := try(body); env != nil {
		return env, nil
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "data: ") {
			if env := try(line[6:]); env != nil {
				return env, nil
			}
		}
	}
	return nil, errors.New("unrecognised search response")
}

func exaSearch(ctx context.Context, tc toolContext, query string) ([]webResult, error) {
	reqBody, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "web_search_exa",
			"arguments": map[string]any{"query": query, "numResults": 8},
		},
	})
	cctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodPost, exaMCPEndpoint, bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("User-Agent", OpenCodeUserAgent)
	res, err := newHTTPClient(tc.provider.UseProxy, tc.env.Proxy).Do(req)
	if err != nil {
		if errors.Is(cctx.Err(), context.DeadlineExceeded) {
			return nil, errors.New("web_search_exa request timed out")
		}
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		return nil, &HTTPStatusError{Status: res.StatusCode, Body: string(b)}
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, exaMaxResponse+1))
	if err != nil {
		return nil, err
	}
	if len(data) > exaMaxResponse {
		return nil, fmt.Errorf("web_search_exa response exceeded %d bytes", exaMaxResponse)
	}
	env, err := parseMCPBody(string(data))
	if err != nil {
		return nil, err
	}
	if env.Error != nil && env.Error.Message != "" {
		return nil, errors.New(env.Error.Message)
	}
	for _, c := range env.Result.Content {
		if c.Text != "" {
			return parseExaResults(c.Text), nil
		}
	}
	return nil, nil
}

func formatWebResults(results []webResult) string {
	if len(results) == 0 {
		return NoSearchResults
	}
	parts := make([]string, 0, len(results))
	for _, r := range results {
		title := r.Title
		if title == "" {
			title = r.URL
		}
		b := fmt.Sprintf("## [%s](%s)", title, r.URL)
		if !r.Published.IsZero() {
			b += "\nPublished: " + r.Published.UTC().Format("2006-01-02T15:04:05.000Z")
		}
		if r.Content != "" {
			b += "\n\n" + r.Content
		}
		parts = append(parts, b)
	}
	return strings.Join(parts, "\n\n")
}

func execWebSearch(ctx context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid websearch arguments: " + err.Error(), IsError: true}
	}
	q := strings.TrimSpace(in.Query)
	if q == "" {
		return ToolExecResult{Output: "query must not be empty", IsError: true}
	}
	if err := checkPerm("websearch", q, map[string]any{"query": q}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	results, err := exaSearch(ctx, tc, q)
	if err != nil {
		msg := fmt.Sprintf("Unable to search the web for %s", q)
		var he *HTTPStatusError
		if errors.As(err, &he) {
			switch he.Status {
			case 429:
				msg = "Web search rate limited (HTTP 429)"
			case 401:
				msg = "Web search authentication failed (HTTP 401)"
			default:
				msg = fmt.Sprintf("Web search request failed (HTTP %d)", he.Status)
			}
		} else {
			msg += ": " + err.Error()
		}
		return ToolExecResult{Output: msg, IsError: true, Metadata: map[string]any{"provider": "exa"}}
	}
	sources := make([]map[string]string, 0, len(results))
	for _, r := range results {
		t := r.Title
		if t == "" {
			t = r.URL
		}
		sources = append(sources, map[string]string{"title": t, "url": r.URL})
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.websearch", map[string]any{"session": tc.session.ID, "query": q})
	}
	return ToolExecResult{
		Output:   formatWebResults(results),
		Metadata: map[string]any{"provider": "exa", "query": q, "count": len(results), "sources": sources},
	}
}
