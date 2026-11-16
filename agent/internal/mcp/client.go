// Package mcp implements bounded MCP JSON-RPC over stdio and Streamable HTTP.
// A client belongs to one run; cancellation closes its complete process tree.
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"aurora3/internal/devprocess"
)

const maxMessage = 1 << 20

var slots = make(chan struct{}, 8)
var validID = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,48}$`)

type Config struct {
	ID       string            `json:"id"`
	Disabled bool              `json:"disabled,omitempty"`
	Command  []string          `json:"command,omitempty"`
	Env      map[string]string `json:"env,omitempty"`
	URL      string            `json:"url,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`
}

func (c Config) Validate() error {
	if !validID.MatchString(c.ID) || (len(c.Command) == 0) == (c.URL == "") || len(c.Command) > 128 || len(c.Env) > 64 || len(c.Headers) > 32 {
		return errors.New("MCP 需要唯一标识及 command 或 URL，且不能同时配置两种传输")
	}
	for _, arg := range c.Command {
		if len(arg) > 8192 || strings.ContainsRune(arg, 0) {
			return errors.New("MCP 命令参数无效")
		}
	}
	for key, value := range c.Env {
		if key == "" || strings.ContainsAny(key, "=\x00") || len(value) > 8192 || strings.ContainsRune(value, 0) {
			return errors.New("MCP 环境变量无效")
		}
	}
	for key, value := range c.Headers {
		if key == "" || len(value) > 8192 || strings.ContainsAny(key+value, "\r\n\x00") {
			return errors.New("MCP HTTP 头无效")
		}
	}
	if c.URL != "" {
		u, err := url.Parse(c.URL)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.Fragment != "" {
			return errors.New("MCP URL 必须为 HTTP(S) 地址")
		}
	}
	return nil
}

type Tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations,omitempty"`
}
type Catalog struct {
	Server       any              `json:"server"`
	Capabilities map[string]any   `json:"capabilities"`
	Tools        []Tool           `json:"tools"`
	Resources    []map[string]any `json:"resources"`
	Prompts      []map[string]any `json:"prompts"`
}
type envelope struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	Method string `json:"method"`
}
type Client struct {
	config           Config
	work             string
	proc             *devprocess.Process
	http             *http.Client
	session, version string
	server           any
	capabilities     map[string]any
	next             atomic.Uint64
	calls            sync.Mutex
	writes           sync.Mutex
	state            sync.Mutex
	stop             sync.Once
	closed           chan struct{}
	replies          chan envelope
	release          func()
}

func Connect(ctx context.Context, cfg Config, work string) (*Client, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if cfg.Disabled {
		return nil, errors.New("MCP 服务已停用")
	}
	select {
	case slots <- struct{}{}:
	default:
		return nil, errors.New("MCP 已达到 8 个连接上限")
	}
	c := &Client{config: cfg, work: work, closed: make(chan struct{}), replies: make(chan envelope, 1), version: "2025-03-26",
		http: &http.Client{Timeout: 35 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	ok := false
	defer func() {
		if !ok {
			c.Close()
		}
	}()
	if len(cfg.Command) > 0 {
		release, err := devprocess.Reserve()
		if err != nil {
			return nil, err
		}
		c.release = release
		env := map[string]string{}
		for _, item := range os.Environ() {
			k, v, ok := strings.Cut(item, "=")
			if ok {
				env[k] = v
			}
		}
		for k, v := range cfg.Env {
			env[k] = v
		}
		var merged []string
		for k, v := range env {
			merged = append(merged, k+"="+v)
		}
		sort.Strings(merged)
		c.proc, err = devprocess.Start(cfg.Command, work, merged)
		if err != nil {
			return nil, err
		}
		go func() { _, _ = io.Copy(io.Discard, c.proc.Stderr) }()
		go c.readLoop()
	}
	result, err := c.Call(ctx, "initialize", map[string]any{
		"protocolVersion": c.version, "capabilities": map[string]any{"roots": map[string]any{"listChanged": false}},
		"clientInfo": map[string]string{"name": "opencode", "version": "1.4.0"},
	})
	if err != nil {
		return nil, err
	}
	var init struct {
		ProtocolVersion string         `json:"protocolVersion"`
		Capabilities    map[string]any `json:"capabilities"`
		ServerInfo      any            `json:"serverInfo"`
	}
	if err := json.Unmarshal(result, &init); err != nil {
		return nil, err
	}
	switch init.ProtocolVersion {
	case "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25":
	default:
		return nil, errors.New("MCP 协议版本不受支持")
	}
	c.state.Lock()
	c.version, c.capabilities, c.server = init.ProtocolVersion, init.Capabilities, init.ServerInfo
	c.state.Unlock()
	if err := c.notify(ctx, "notifications/initialized", map[string]any{}); err != nil {
		return nil, err
	}
	ok = true
	return c, nil
}
func (c *Client) Close() {
	c.stop.Do(func() {
		close(c.closed)
		if c.proc != nil {
			c.proc.Close()
		}
		if c.release != nil {
			c.release()
		}
		c.state.Lock()
		hasSession := c.session != ""
		c.state.Unlock()
		if hasSession && c.config.URL != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			req, _ := http.NewRequestWithContext(ctx, http.MethodDelete, c.config.URL, nil)
			c.headers(req)
			if resp, err := c.http.Do(req); err == nil {
				resp.Body.Close()
			}
			cancel()
		}
		c.http.CloseIdleConnections()
		<-slots
	})
}
func (c *Client) write(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data) > maxMessage {
		return errors.New("MCP 请求超过 1 MiB")
	}
	c.writes.Lock()
	defer c.writes.Unlock()
	select {
	case <-c.closed:
		return errors.New("MCP 已关闭")
	default:
	}
	_, err = c.proc.Stdin.Write(append(data, '\n'))
	return err
}
func (c *Client) readLoop() {
	defer c.Close()
	scanner := bufio.NewScanner(c.proc.Stdout)
	scanner.Buffer(make([]byte, 4096), maxMessage)
	for scanner.Scan() {
		var value envelope
		if json.Unmarshal(scanner.Bytes(), &value) != nil {
			return
		}
		if value.Method != "" {
			if len(value.ID) == 0 {
				continue
			}
			reply := map[string]any{"jsonrpc": "2.0", "id": value.ID}
			switch value.Method {
			case "ping":
				reply["result"] = map[string]any{}
			case "roots/list":
				p := strings.ReplaceAll(c.work, `\`, "/")
				if !strings.HasPrefix(p, "/") {
					p = "/" + p
				}
				reply["result"] = map[string]any{"roots": []any{map[string]string{"uri": (&url.URL{Scheme: "file", Path: p}).String(), "name": "workspace"}}}
			default:
				reply["error"] = map[string]any{"code": -32601, "message": "Client capability not supported"}
			}
			if c.write(reply) != nil {
				return
			}
			continue
		}
		select {
		case c.replies <- value:
		case <-c.closed:
			return
		default:
			return
		}
	}
}
func (c *Client) headers(req *http.Request) {
	c.state.Lock()
	defer c.state.Unlock()
	for k, v := range c.config.Headers {
		req.Header.Set(k, v)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("User-Agent", "opencode/stable/1.4.0/opencode")
	req.Header.Set("originator", "opencode")
	req.Header.Set("x-opencode-client", "cli")
	req.Header.Set("MCP-Protocol-Version", c.version)
	if c.session != "" {
		req.Header.Set("Mcp-Session-Id", c.session)
	}
}
func (c *Client) post(ctx context.Context, value any, id string) (envelope, error) {
	var result envelope
	data, err := json.Marshal(value)
	if err != nil {
		return result, err
	}
	if len(data) > maxMessage {
		return result, errors.New("MCP 请求超过 1 MiB")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.config.URL, bytes.NewReader(data))
	if err != nil {
		return result, err
	}
	c.headers(req)
	resp, err := c.http.Do(req)
	if err != nil {
		return result, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return result, fmt.Errorf("MCP HTTP %d", resp.StatusCode)
	}
	if session := resp.Header.Get("Mcp-Session-Id"); session != "" {
		if len(session) > 1024 {
			return result, errors.New("MCP 会话标识过长")
		}
		c.state.Lock()
		c.session = session
		c.state.Unlock()
	}
	if id == "" {
		return result, nil
	}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		scanner := bufio.NewScanner(io.LimitReader(resp.Body, 2*maxMessage+1))
		scanner.Buffer(make([]byte, 4096), maxMessage)
		var event strings.Builder
		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				if event.Len() == 0 {
					continue
				}
				if err := json.Unmarshal([]byte(event.String()), &result); err != nil {
					return result, err
				}
				if string(result.ID) == id {
					return result, nil
				}
				event.Reset()
			} else if strings.HasPrefix(line, "data:") {
				event.WriteString(strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
				event.WriteByte('\n')
				if event.Len() > maxMessage {
					return result, errors.New("MCP 事件超过 1 MiB")
				}
			}
		}
		return result, errors.New("MCP 事件流结束且没有对应回复")
	}
	data, err = io.ReadAll(io.LimitReader(resp.Body, maxMessage+1))
	if err != nil {
		return result, err
	}
	if len(data) > maxMessage {
		return result, errors.New("MCP 回复超过 1 MiB")
	}
	err = json.Unmarshal(data, &result)
	return result, err
}
func (c *Client) notify(ctx context.Context, method string, params any) error {
	v := map[string]any{"jsonrpc": "2.0", "method": method, "params": params}
	if c.proc != nil {
		return c.write(v)
	}
	_, err := c.post(ctx, v, "")
	return err
}
func (c *Client) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	c.calls.Lock()
	defer c.calls.Unlock()
	select {
	case <-c.closed:
		return nil, errors.New("MCP 已关闭")
	default:
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	// A blocked stdin write, incomplete response, or cancelled tool cannot keep
	// its process alive after the request has returned.
	stop := context.AfterFunc(ctx, c.Close)
	defer stop()
	id := fmt.Sprint(c.next.Add(1))
	request := map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id), "method": method, "params": params}
	var reply envelope
	var err error
	if c.proc != nil {
		if err = c.write(request); err == nil {
			select {
			case reply = <-c.replies:
			case <-ctx.Done():
				err = ctx.Err()
			case <-c.closed:
				err = errors.New("MCP 连接已关闭")
			}
		}
	} else {
		reply, err = c.post(ctx, request, id)
	}
	if err != nil {
		return nil, err
	}
	if string(reply.ID) != id {
		return nil, errors.New("MCP 回复标识不匹配")
	}
	if reply.Error != nil {
		return nil, fmt.Errorf("MCP %d: %s", reply.Error.Code, reply.Error.Message)
	}
	if len(reply.Result) == 0 {
		return nil, errors.New("MCP 回复缺少 result")
	}
	return reply.Result, nil
}
func (c *Client) list(ctx context.Context, method, key string) ([]json.RawMessage, error) {
	var out []json.RawMessage
	cursor := ""
	seen := map[string]bool{}
	for page := 0; page < 8; page++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		data, err := c.Call(ctx, method, params)
		if err != nil {
			return nil, err
		}
		var response map[string]json.RawMessage
		if err := json.Unmarshal(data, &response); err != nil {
			return nil, err
		}
		var entries []json.RawMessage
		if err := json.Unmarshal(response[key], &entries); err != nil {
			return nil, err
		}
		out = append(out, entries...)
		if len(out) > 128 {
			return nil, errors.New("MCP 目录超过 128 项")
		}
		next := ""
		_ = json.Unmarshal(response["nextCursor"], &next)
		if next == "" {
			return out, nil
		}
		if seen[next] {
			return nil, errors.New("MCP 分页游标重复")
		}
		seen[next] = true
		cursor = next
	}
	return nil, errors.New("MCP 目录超过 8 页")
}
func (c *Client) Catalog(ctx context.Context) (Catalog, error) {
	cat := Catalog{Server: c.server, Capabilities: c.capabilities, Tools: []Tool{}, Resources: []map[string]any{}, Prompts: []map[string]any{}}
	for _, kind := range []string{"tools", "resources", "prompts"} {
		if _, ok := c.capabilities[kind]; !ok {
			continue
		}
		entries, err := c.list(ctx, kind+"/list", kind)
		if err != nil {
			return cat, err
		}
		for _, data := range entries {
			if kind == "tools" {
				var t Tool
				if err := json.Unmarshal(data, &t); err != nil {
					return cat, err
				}
				if t.Name == "" || len(t.Name) > 128 || len(t.Description) > 8192 || t.InputSchema == nil {
					return cat, errors.New("MCP 工具定义无效")
				}
				cat.Tools = append(cat.Tools, t)
			} else {
				var entry map[string]any
				if err := json.Unmarshal(data, &entry); err != nil {
					return cat, err
				}
				if kind == "resources" {
					cat.Resources = append(cat.Resources, entry)
				} else {
					cat.Prompts = append(cat.Prompts, entry)
				}
			}
		}
	}
	return cat, nil
}
