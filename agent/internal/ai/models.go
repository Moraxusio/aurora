package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// ToolDef matches OpenCode's tool definition schema.
type ToolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

// LLMRequest is the normalized protocol-independent model invocation.
type LLMRequest struct {
	SessionID   string
	AffinityID  string // parent/root session ID for prompt-cache routing
	Initiator   string // "user" | "agent"
	Provider    ProviderConfig
	System      []string
	Messages    []Message
	Tools       []ToolDef
	MaxTokens   int
	Temperature *float64
}

// LLMDelta is emitted incrementally while streaming a model response.
type LLMDelta struct {
	Type         string // "text" | "reasoning" | "tool-call-start" | "tool-call-end"
	Text         string
	Signature    string
	Redacted     string
	ToolCallID   string
	ToolName     string
	ToolInput    json.RawMessage
	ProviderMeta map[string]any
}

// LLMResponse is the settled outcome of one LLM streaming call.
type LLMResponse struct {
	Parts  []Part
	Finish string // "stop" | "tool-calls" | "length" | "content-filter"
	Usage  Usage
}

// ModelInfo describes a model returned by ai.models (/models discovery).
type ModelInfo struct {
	ID            string `json:"id"`
	Name          string `json:"name,omitempty"`
	ContextWindow int    `json:"context_window,omitempty"`
	MaxTokens     int    `json:"max_tokens,omitempty"`
}

// HTTPStatusError carries an upstream HTTP status code and body for retry/overflow classification.
type HTTPStatusError struct {
	Status int
	Body   string
}

func (e *HTTPStatusError) Error() string {
	msg := strings.TrimSpace(e.Body)
	var parsed struct {
		Error any `json:"error"`
	}
	if json.Unmarshal([]byte(e.Body), &parsed) == nil && parsed.Error != nil {
		switch v := parsed.Error.(type) {
		case string:
			if v != "" {
				msg = v
			}
		case map[string]any:
			t, _ := v["type"].(string)
			m, _ := v["message"].(string)
			if t != "" && m != "" {
				msg = t + ": " + m
			} else if m != "" {
				msg = m
			}
		}
	}
	if len(msg) > 600 {
		msg = msg[:600] + "…"
	}
	if msg == "" {
		msg = http.StatusText(e.Status)
	}
	return fmt.Sprintf("provider HTTP %d: %s", e.Status, msg)
}

func IsContextOverflowError(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	var he *HTTPStatusError
	if errors.As(err, &he) && he.Status == 413 {
		return true
	}
	patterns := []string{
		"context_length_exceeded",
		"context window",
		"maximum context length",
		"prompt is too long",
		"too many tokens",
		"input is too long",
		"request_too_large",
		"model_context_window_exceeded",
	}
	for _, p := range patterns {
		if strings.Contains(s, p) {
			return true
		}
	}
	return false
}

func IsRetryableProviderError(err error) bool {
	var he *HTTPStatusError
	if errors.As(err, &he) {
		switch he.Status {
		case 408, 409, 429, 500, 502, 503, 504, 529:
			return true
		}
	}
	return false
}

// newHTTPClient builds an HTTP client that optionally routes through Aurora's proxysvc node (px.GitEnv).
func newHTTPClient(useProxy bool, proxyEnv func() map[string]string) *http.Client {
	tr := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   20 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   20 * time.Second,
		ResponseHeaderTimeout: 120 * time.Second,
		IdleConnTimeout:       90 * time.Second,
	}
	if useProxy && proxyEnv != nil {
		var proxyURL *url.URL
		for k, v := range proxyEnv() {
			if v == "" {
				continue
			}
			if strings.EqualFold(k, "HTTPS_PROXY") || strings.EqualFold(k, "HTTP_PROXY") || strings.EqualFold(k, "ALL_PROXY") {
				if u, err := url.Parse(v); err == nil {
					proxyURL = u
					if strings.EqualFold(k, "HTTPS_PROXY") {
						break
					}
				}
			}
		}
		if proxyURL != nil {
			tr.Proxy = http.ProxyURL(proxyURL)
		}
	} else if !useProxy {
		tr.Proxy = nil
	}
	return &http.Client{Transport: tr}
}

// applyOpenCodeHeaders attaches OpenCode's exact HTTP headers so OpenCode-aware API gateways
// recognize the harness, enable prompt caching, and optimize session routing.
func applyOpenCodeHeaders(h http.Header, req LLMRequest) {
	h.Set("Content-Type", "application/json")
	h.Set("Accept", "text/event-stream")
	h.Set("User-Agent", OpenCodeUserAgent)
	h.Set("HTTP-Referer", OpenCodeReferer)
	h.Set("X-Title", OpenCodeTitle)
	h.Set("x-opencode-client", OpenCodeClient)
	if req.SessionID != "" {
		h.Set("x-opencode-session-id", req.SessionID)
		h.Set("x-opencode-session", req.SessionID)
	}
	affinity := req.AffinityID
	if affinity == "" {
		affinity = req.SessionID
	}
	if affinity != "" {
		h.Set("x-session-affinity", affinity)
	}
	if req.Initiator != "" {
		h.Set("x-initiator", req.Initiator)
	}

	// Auth header: supports explicit AuthMode or protocol-aware default
	authMode := strings.ToLower(strings.TrimSpace(req.Provider.AuthMode))
	apiKey := strings.TrimSpace(req.Provider.APIKey)
	if apiKey != "" {
		switch authMode {
		case "x-api-key":
			h.Set("x-api-key", apiKey)
		case "bearer":
			h.Set("Authorization", "Bearer "+apiKey)
		default:
			if req.Provider.Protocol == "anthropic-messages" {
				// Official Anthropic uses x-api-key; many OpenCode gateways accept either x-api-key or Bearer.
				// Setting x-api-key and Authorization Bearer when custom gateway is used maximizes compatibility;
				// official api.anthropic.com accepts x-api-key cleanly.
				h.Set("x-api-key", apiKey)
				if !strings.Contains(strings.ToLower(req.Provider.BaseURL), "api.anthropic.com") {
					h.Set("Authorization", "Bearer "+apiKey)
				}
			} else {
				h.Set("Authorization", "Bearer "+apiKey)
			}
		}
	}

	// User-configured custom headers override anything above if specified
	for k, v := range req.Provider.Headers {
		if strings.TrimSpace(k) != "" {
			h.Set(k, v)
		}
	}
}

func resolveEndpoint(baseURL, defaultBase, suffix string) string {
	base := strings.TrimSpace(baseURL)
	if base == "" {
		base = defaultBase
	}
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, suffix) {
		return base
	}
	return base + suffix
}

// sseEvent represents one parsed Server-Sent Event frame.
type sseEvent struct {
	Event string
	Data  string
}

// readSSE parses an HTTP text/event-stream body (supporting arbitrarily long lines via bufio.Reader)
// and invokes onEvent for each dispatched SSE frame.
func readSSE(r io.Reader, onEvent func(sseEvent) error) error {
	br := bufio.NewReaderSize(r, 64*1024)
	var eventName string
	var dataLines []string

	flush := func() error {
		if len(dataLines) == 0 && eventName == "" {
			return nil
		}
		ev := sseEvent{
			Event: eventName,
			Data:  strings.Join(dataLines, "\n"),
		}
		eventName = ""
		dataLines = dataLines[:0]
		if ev.Data == "" {
			return nil
		}
		return onEvent(ev)
	}

	for {
		lineBytes, err := br.ReadBytes('\n')
		if len(lineBytes) > 0 {
			line := strings.TrimRight(string(lineBytes), "\r\n")
			if line == "" {
				if ferr := flush(); ferr != nil {
					return ferr
				}
			} else if strings.HasPrefix(line, ":") {
				// SSE comment / keepalive
			} else if field, val, ok := strings.Cut(line, ":"); ok {
				val = strings.TrimPrefix(val, " ")
				switch field {
				case "event":
					eventName = val
				case "data":
					dataLines = append(dataLines, val)
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return flush()
			}
			return err
		}
	}
}

var errSSEStreamDone = errors.New("sse stream done")

// StreamLLM dispatches an LLMRequest through the selected OpenCode protocol with automatic retry on transient errors.
func StreamLLM(ctx context.Context, req LLMRequest, proxyEnv func() map[string]string, onDelta func(LLMDelta)) (LLMResponse, error) {
	protocol := strings.ToLower(strings.TrimSpace(req.Provider.Protocol))
	if protocol == "" {
		protocol = "openai-chat"
	}
	req.Provider.Protocol = protocol

	var lastErr error
	backoffs := []time.Duration{0, 1500 * time.Millisecond, 3500 * time.Millisecond}
	for attempt, wait := range backoffs {
		if wait > 0 {
			select {
			case <-ctx.Done():
				return LLMResponse{}, ctx.Err()
			case <-time.After(wait):
			}
		}
		emittedAny := false
		wrappedDelta := func(d LLMDelta) {
			emittedAny = true
			if onDelta != nil {
				onDelta(d)
			}
		}

		var resp LLMResponse
		var err error
		switch protocol {
		case "anthropic-messages", "anthropic":
			resp, err = streamAnthropicMessages(ctx, req, proxyEnv, wrappedDelta)
		case "openai-responses", "responses":
			resp, err = streamOpenAIResponses(ctx, req, proxyEnv, wrappedDelta)
		default:
			resp, err = streamOpenAIChat(ctx, req, proxyEnv, wrappedDelta)
		}
		if err == nil {
			return resp, nil
		}
		lastErr = err
		// Only retry if no partial deltas were streamed yet and error is transient
		if emittedAny || !IsRetryableProviderError(err) || attempt == len(backoffs)-1 {
			return LLMResponse{}, err
		}
	}
	return LLMResponse{}, lastErr
}

// FetchModels queries the provider's /models endpoint using OpenCode headers so the user can pick models directly in Aurora.
func FetchModels(ctx context.Context, cfg ProviderConfig, proxyEnv func() map[string]string) ([]ModelInfo, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	defaultBase := "https://api.openai.com/v1"
	if strings.HasPrefix(cfg.Protocol, "anthropic") {
		defaultBase = "https://api.anthropic.com/v1"
	}
	base := strings.TrimSpace(cfg.BaseURL)
	if base == "" {
		base = defaultBase
	}
	base = strings.TrimRight(base, "/")
	for _, suf := range []string{"/chat/completions", "/messages", "/responses"} {
		base = strings.TrimSuffix(base, suf)
	}
	base = strings.TrimSuffix(base, "/models")

	// Gateways are often given without the /v1 suffix and then answer the
	// models URL with their web page. Try the address as typed, then with /v1.
	candidates := []string{base + "/models"}
	if !strings.HasSuffix(base, "/v1") && !strings.Contains(base, "/v1/") {
		candidates = append(candidates, base+"/v1/models")
	}
	var lastErr error
	for _, endpoint := range candidates {
		list, err := fetchModelsAt(cctx, cfg, proxyEnv, endpoint)
		if err == nil {
			return list, nil
		}
		lastErr = err
		var he *HTTPStatusError
		if errors.As(err, &he) && (he.Status == 401 || he.Status == 403) {
			break // the key is the problem, not the address
		}
	}
	return nil, lastErr
}

var errNotJSON = errors.New("接口返回的不是 JSON（像是网页）。请检查 Base URL：通常要以 /v1 结尾，且不要包含 /chat/completions")

func fetchModelsAt(cctx context.Context, cfg ProviderConfig, proxyEnv func() map[string]string, endpoint string) ([]ModelInfo, error) {
	httpReq, err := http.NewRequestWithContext(cctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	applyOpenCodeHeaders(httpReq.Header, LLMRequest{Provider: cfg})
	httpReq.Header.Set("Accept", "application/json")
	if strings.HasPrefix(cfg.Protocol, "anthropic") && httpReq.Header.Get("anthropic-version") == "" {
		httpReq.Header.Set("anthropic-version", "2023-06-01")
	}

	client := newHTTPClient(cfg.UseProxy, proxyEnv)
	res, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 4*1024*1024))
	if err != nil {
		return nil, err
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, &HTTPStatusError{Status: res.StatusCode, Body: string(body)}
	}
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		return nil, errNotJSON
	}

	var parsed struct {
		Data []struct {
			ID            string `json:"id"`
			Name          string `json:"name"`
			DisplayName   string `json:"display_name"`
			ContextLength int    `json:"context_length"`
			MaxInput      int    `json:"max_input_tokens"`
		} `json:"data"`
		Models []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			DisplayName string `json:"display_name"`
		} `json:"models"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(body), &parsed); err != nil {
		return nil, fmt.Errorf("invalid /models JSON: %w", err)
	}

	var list []ModelInfo
	seen := map[string]bool{}
	for _, m := range parsed.Data {
		if m.ID == "" || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		nm := m.DisplayName
		if nm == "" {
			nm = m.Name
		}
		cw := m.ContextLength
		if cw == 0 {
			cw = m.MaxInput
		}
		list = append(list, ModelInfo{ID: m.ID, Name: nm, ContextWindow: cw})
	}
	for _, m := range parsed.Models {
		id := m.ID
		if id == "" {
			id = strings.TrimPrefix(m.Name, "models/")
		}
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		list = append(list, ModelInfo{ID: id, Name: m.DisplayName})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list, nil
}
