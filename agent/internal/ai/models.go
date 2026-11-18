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
	"strconv"
	"strings"
	"time"

	"aurora3/internal/proxyroute"
)

// ToolDef matches OpenCode's tool definition schema.
type ToolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

// LLMRequest is the normalized protocol-independent model invocation.
type LLMRequest struct {
	SessionID       string
	AffinityID      string // parent/root session ID for prompt-cache routing
	Initiator       string // "user" | "agent"
	Provider        ProviderConfig
	System          []string
	Messages        []Message
	Tools           []ToolDef
	MaxTokens       int
	BudgetAuxiliary bool // title/compaction share tokens and cost, not tool steps
	Temperature     *float64
	LoadAttachment  func(Part) ([]byte, error)
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
	ID                string   `json:"id"`
	Name              string   `json:"name,omitempty"`
	ContextWindow     int      `json:"context_window,omitempty"`
	MaxTokens         int      `json:"max_tokens,omitempty"`
	InputModalities   []string `json:"input_modalities,omitempty"`
	SupportsImage     bool     `json:"supports_image"`
	ImageSupportKnown bool     `json:"image_support_known,omitempty"`
}

// HTTPStatusError carries an upstream HTTP status code and body for retry/overflow classification.
type HTTPStatusError struct {
	Status int
	Body   string
	// RetryAfter is what the upstream asked for with a Retry-After header; zero
	// when it sent none.
	RetryAfter time.Duration
}

// maxRetryWait caps how long one Retry-After may hold a request: a gateway that
// asks for an hour must not freeze the run.
const maxRetryWait = 30 * time.Second

// retryAfter reads a Retry-After header, in seconds or as an HTTP date. A
// missing, malformed or non-positive value is zero; a large one is capped.
func retryAfter(h http.Header, now time.Time) time.Duration {
	v := strings.TrimSpace(h.Get("Retry-After"))
	if v == "" {
		return 0
	}
	var wait time.Duration
	if n, err := strconv.Atoi(v); err == nil {
		wait = time.Duration(n) * time.Second
	} else if t, err := http.ParseTime(v); err == nil {
		wait = t.Sub(now)
	}
	if wait <= 0 {
		return 0
	}
	if wait > maxRetryWait {
		wait = maxRetryWait
	}
	return wait
}

// statusError builds the error for a non-2xx response, remembering Retry-After.
func statusError(res *http.Response, body []byte) *HTTPStatusError {
	return &HTTPStatusError{Status: res.StatusCode, Body: string(body), RetryAfter: retryAfter(res.Header, time.Now())}
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
func newHTTPClient(useProxy bool, proxyEnv func() map[string]string, modes ...string) *http.Client {
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
	if len(modes) > 0 && modes[0] != "" {
		tr.Proxy = proxyroute.HTTP(modes[0], proxyEnv)
	} else if useProxy && proxyEnv != nil {
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

	// Preserve the gateway identity contract while allowing custom routing/auth.
	for k, v := range req.Provider.Headers {
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "user-agent", "originator", "x-opencode-client":
			continue
		}
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
	var optionErr error
	req.Provider, optionErr = prepareModelOptions(req.Provider)
	if optionErr != nil {
		return LLMResponse{}, optionErr
	}
	filtered := make([]ToolDef, 0, len(req.Tools))
	for _, tool := range req.Tools {
		if req.Provider.allows("tool_calling") && req.Provider.allows(tool.Name) {
			filtered = append(filtered, tool)
		}
	}
	req.Tools = filtered
	var mediaErr error
	req.Messages, mediaErr = materializeAttachments(req.Messages, req.LoadAttachment, req.Provider)
	if mediaErr != nil {
		return LLMResponse{}, mediaErr
	}
	var prepErr error
	req.Provider, prepErr = prepareSubscription(req.Provider)
	if prepErr != nil {
		return LLMResponse{}, prepErr
	}
	protocol := strings.ToLower(strings.TrimSpace(req.Provider.Protocol))
	if protocol == "" {
		protocol = "openai-chat"
	}
	req.Provider.Protocol = protocol

	var lastErr error
	backoffs := []time.Duration{0, 1500 * time.Millisecond, 3500 * time.Millisecond}
	for attempt, wait := range backoffs {
		// A gateway that said how long to wait is believed, but never for less
		// than our own backoff: Retry-After 1 after a 429 must not make the
		// second try come sooner than it would have.
		var he *HTTPStatusError
		if errors.As(lastErr, &he) && he.RetryAfter > wait {
			wait = he.RetryAfter
		}
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
	var err error
	cfg, err = prepareSubscription(cfg)
	if err != nil {
		return nil, err
	}
	if cfg.AuthMode == ChatGPTAuthMode {
		return subscriptionModelSuggestions(cfg), nil
	}
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
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, errors.New("模型 Base URL 必须是有效的 HTTP(S) 地址")
	}
	base = strings.TrimRight(u.Path, "/")
	for _, suf := range []string{"/chat/completions", "/messages", "/responses"} {
		base = strings.TrimSuffix(base, suf)
	}
	base = strings.TrimSuffix(base, "/models")

	// Gateways are often given without the /v1 suffix and then answer the
	// models URL with their web page. Try the address as typed, then with /v1.
	u.Path = base + "/models"
	candidates := []string{u.String()}
	if !strings.HasSuffix(base, "/v1") && !strings.Contains(base, "/v1/") {
		u.Path = base + "/v1/models"
		candidates = append(candidates, u.String())
	}
	var lastErr error
	emptySuccess := false
	for _, endpoint := range candidates {
		list, err := fetchModelsAt(cctx, cfg, proxyEnv, endpoint)
		if err == nil && len(list) > 0 {
			return list, nil
		}
		if err == nil {
			emptySuccess = true
			continue
		}
		lastErr = err
		var he *HTTPStatusError
		if errors.As(err, &he) && (he.Status == 401 || he.Status == 403) {
			break // the key is the problem, not the address
		}
	}
	if emptySuccess {
		return []ModelInfo{}, nil
	}
	return nil, lastErr
}

var errNotJSON = errors.New("接口返回的不是 JSON（像是网页）。请检查 Base URL：通常要以 /v1 结尾，且不要包含 /chat/completions")

func fetchModelsAt(cctx context.Context, cfg ProviderConfig, proxyEnv func() map[string]string, endpoint string) ([]ModelInfo, error) {
	return fetchModelPages(cctx, cfg, proxyEnv, endpoint, 0)
}

func fetchModelPages(cctx context.Context, cfg ProviderConfig, proxyEnv func() map[string]string, endpoint string, page int) ([]ModelInfo, error) {
	if page >= 20 {
		return nil, errors.New("模型列表分页超过 20 页，请缩小范围或手动添加")
	}
	httpReq, err := http.NewRequestWithContext(cctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	applyOpenCodeHeaders(httpReq.Header, LLMRequest{Provider: cfg})
	httpReq.Header.Set("Accept", "application/json")
	if strings.HasPrefix(cfg.Protocol, "anthropic") && httpReq.Header.Get("anthropic-version") == "" {
		httpReq.Header.Set("anthropic-version", "2023-06-01")
	}

	client := newHTTPClient(cfg.UseProxy, proxyEnv, cfg.ProxyMode)
	defer client.CloseIdleConnections()
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error { return http.ErrUseLastResponse }
	res, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 4*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(body) > 4*1024*1024 {
		return nil, errors.New("模型列表超过 4 MiB，请手动添加模型")
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, &HTTPStatusError{Status: res.StatusCode, Body: string(body)}
	}
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		return nil, errNotJSON
	}

	list, err := parseModelList(body)
	if err != nil {
		return nil, err
	}
	var pagination struct {
		HasMore bool   `json:"has_more"`
		LastID  string `json:"last_id"`
	}
	_ = json.Unmarshal(body, &pagination)
	if pagination.HasMore {
		if pagination.LastID == "" {
			return nil, errors.New("模型分页缺少 last_id")
		}
		u, err := url.Parse(endpoint)
		if err != nil {
			return nil, err
		}
		q := u.Query()
		if q.Get("after_id") == pagination.LastID {
			return nil, errors.New("模型接口重复返回分页游标")
		}
		q.Set("after_id", pagination.LastID)
		u.RawQuery = q.Encode()
		next, err := fetchModelPages(cctx, cfg, proxyEnv, u.String(), page+1)
		if err != nil {
			return nil, err
		}
		seen := map[string]bool{}
		for _, m := range list {
			seen[m.ID] = true
		}
		for _, m := range next {
			if !seen[m.ID] {
				seen[m.ID] = true
				list = append(list, m)
			}
		}
		sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	}
	return list, nil
}

func parseModelList(body []byte) ([]ModelInfo, error) {
	type row struct {
		ID              string   `json:"id"`
		Name            string   `json:"name"`
		DisplayName     string   `json:"display_name"`
		ContextLength   int      `json:"context_length"`
		ContextWindow   int      `json:"context_window"`
		MaxInput        int      `json:"max_input_tokens"`
		MaxTokens       int      `json:"max_output_tokens"`
		InputModalities []string `json:"input_modalities"`
		Modalities      []string `json:"modalities"`
		SupportsImage   *bool    `json:"supports_image"`
		SupportsVision  *bool    `json:"supports_vision"`
		Vision          *bool    `json:"vision"`
	}
	var parsed struct {
		Data   []json.RawMessage `json:"data"`
		Models []json.RawMessage `json:"models"`
	}
	var entries []json.RawMessage
	if len(bytes.TrimSpace(body)) > 0 && bytes.TrimSpace(body)[0] == '[' {
		if err := json.Unmarshal(body, &entries); err != nil {
			return nil, fmt.Errorf("invalid /models JSON: %w", err)
		}
	} else {
		if err := json.Unmarshal(body, &parsed); err != nil {
			return nil, fmt.Errorf("invalid /models JSON: %w", err)
		}
		if parsed.Data == nil && parsed.Models == nil {
			return nil, errors.New("JSON 中没有 data/models 列表，请检查 API 地址或手动添加模型")
		}
		entries = append(parsed.Data, parsed.Models...)
	}
	list := []ModelInfo{}
	seen := map[string]bool{}
	for _, raw := range entries {
		var id string
		var m row
		if json.Unmarshal(raw, &id) != nil {
			if json.Unmarshal(raw, &m) != nil {
				continue
			}
			id = m.ID
			if id == "" {
				id = strings.TrimPrefix(m.Name, "models/")
			}
		}
		id = strings.TrimSpace(id)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		name := m.DisplayName
		if name == "" {
			name = m.Name
		}
		cw := m.ContextLength
		if cw == 0 {
			cw = m.ContextWindow
		}
		if cw == 0 {
			cw = m.MaxInput
		}
		modalities := append([]string{}, m.InputModalities...)
		modalities = append(modalities, m.Modalities...)
		known := false
		supportsImage := false
		if m.SupportsImage != nil {
			known, supportsImage = true, *m.SupportsImage
		}
		if m.SupportsVision != nil {
			known, supportsImage = true, *m.SupportsVision
		}
		if m.Vision != nil {
			known, supportsImage = true, *m.Vision
		}
		for _, modality := range modalities {
			m := strings.ToLower(modality)
			if strings.Contains(m, "image") || strings.Contains(m, "vision") {
				known, supportsImage = true, true
			}
		}
		nestedKnown, nestedImage, nestedModalities := detectImageCapability(raw)
		known = known || nestedKnown
		supportsImage = supportsImage || nestedImage
		modalities = append(modalities, nestedModalities...)
		model := ModelInfo{ID: id, Name: name, ContextWindow: cw, MaxTokens: m.MaxTokens, InputModalities: modalities, SupportsImage: supportsImage, ImageSupportKnown: known}
		list = append(list, model)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list, nil
}

// detectImageCapability accepts the loose capability shapes used by OpenAI-
// compatible gateways: top-level flags, `capabilities`, `architecture`, and
// modality arrays. Unknown remains unknown; a model name is never treated as
// evidence of image support.
func detectImageCapability(raw json.RawMessage) (known, supports bool, modalities []string) {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return false, false, nil
	}
	var walk func(any)
	walk = func(node any) {
		obj, ok := node.(map[string]any)
		if !ok {
			return
		}
		for key, child := range obj {
			switch strings.ToLower(key) {
			case "supports_image", "supports_vision", "vision", "image_input", "image_support":
				if flag, ok := child.(bool); ok {
					known = true
					supports = supports || flag
				}
			case "modalities", "input_modalities", "input_modality":
				if list, ok := child.([]any); ok {
					for _, item := range list {
						if text, ok := item.(string); ok {
							modalities = append(modalities, text)
							lower := strings.ToLower(text)
							if strings.Contains(lower, "image") || strings.Contains(lower, "vision") {
								known, supports = true, true
							}
						}
					}
				}
			}
			walk(child)
		}
	}
	walk(value)
	return known, supports, modalities
}
