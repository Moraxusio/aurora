package terminal

import (
	"aurora3/internal/paths"
	"aurora3/internal/service"
	"aurora3/internal/winlocal"
	"aurora3/internal/wire"
	"context"
	"encoding/json"
	"net"
	"os"
	"regexp"
	"sort"
	"sync"
	"time"
)

type Root struct{ ID, Path string }
type Env struct {
	Roots    []Root
	mu       sync.Mutex
	sessions map[string]*localSession
}
type localSession struct {
	console   *winlocal.Console
	cwd       string
	created   int64
	proxy     bool
	mu        sync.Mutex
	history   []byte
	listeners map[chan []byte]struct{}
	done      chan struct{}
}
type svc struct{ e *Env }

func (e *Env) Service() service.Service        { return svc{e} }
func (svc) ID() string                         { return "terminal" }
func (svc) Dependencies() []service.Dependency { return nil }
func (v svc) Switched(on bool) {
	if !on {
		v.e.Close()
	}
}
func (v svc) Operations() []service.Operation {
	return []service.Operation{{Name: "session.list", Handle: v.e.list}, {Name: "session.create", Handle: v.e.create}, {Name: "session.kill", Handle: v.e.kill}, {Name: "terminal", Stream: v.e.attach}}
}
func (e *Env) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sessions {
		s.console.Close()
	}
	e.sessions = map[string]*localSession{}
}
func (e *Env) get(name string) *localSession {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.sessions[name]
}
func (e *Env) list(context.Context, json.RawMessage) (any, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := []map[string]any{}
	for n, s := range e.sessions {
		select {
		case <-s.done:
			delete(e.sessions, n)
			continue
		default:
		}
		out = append(out, map[string]any{"name": n, "windows": 1, "created": s.created, "proxy": s.proxy})
	}
	sort.Slice(out, func(i, j int) bool { return out[i]["name"].(string) < out[j]["name"].(string) })
	return map[string]any{"sessions": out, "backend": "conpty", "persistent": false}, nil
}

var localName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,48}$`)

func (e *Env) create(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Name, Root, Path string
		NoProfile        bool `json:"no_profile"`
	}
	if json.Unmarshal(raw, &a) != nil || !localName.MatchString(a.Name) {
		return nil, wire.Errf(wire.CodeBadRequest, "终端名称无效")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.sessions == nil {
		e.sessions = map[string]*localSession{}
	}
	if old := e.sessions[a.Name]; old != nil {
		select {
		case <-old.done:
			delete(e.sessions, a.Name)
		default:
			return map[string]any{"existed": true, "proxy": old.proxy}, nil
		}
	}
	if len(e.sessions) >= 32 {
		return nil, wire.Errf(wire.CodeBadRequest, "最多同时运行 32 个本地终端")
	}
	root := ""
	for _, r := range e.Roots {
		if a.Root == r.ID || (a.Root == "" && root == "") {
			root = r.Path
		}
	}
	if root == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "未知的根目录")
	}
	cwd, err := paths.Resolve(root, a.Path)
	if err != nil {
		return nil, paths.WireError(err)
	}
	px := winlocal.ProxyEnv()
	hasProxy := px["HTTP_PROXY"] != "" || px["HTTPS_PROXY"] != "" || px["ALL_PROXY"] != ""
	extra := []string{}
	if a.NoProfile {
		extra = append(extra, "-NoProfile")
	}
	con, err := winlocal.StartConsole(cwd, winlocal.Merge(os.Environ(), px), 100, 30, extra...)
	if err != nil {
		return nil, wire.Errf(wire.CodeUnavailable, "无法启动本地 PowerShell：%v", err)
	}
	s := &localSession{console: con, cwd: cwd, created: time.Now().Unix(), proxy: hasProxy, listeners: map[chan []byte]struct{}{}, done: make(chan struct{})}
	e.sessions[a.Name] = s
	go func() {
		defer close(s.done)
		defer con.Close()
		buf := make([]byte, 16384)
		for {
			n, err := con.Output.Read(buf)
			if n > 0 {
				chunk := append([]byte{}, buf[:n]...)
				s.mu.Lock()
				s.history = append(s.history, chunk...)
				if len(s.history) > 256<<10 {
					s.history = s.history[len(s.history)-(256<<10):]
				}
				for ch := range s.listeners {
					select {
					case ch <- chunk:
					default:
						close(ch)
						delete(s.listeners, ch)
					}
				}
				s.mu.Unlock()
			}
			if err != nil {
				return
			}
		}
	}()
	return map[string]any{"name": a.Name, "proxy": hasProxy, "backend": "conpty"}, nil
}
func (e *Env) kill(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct{ Name string }
	_ = json.Unmarshal(raw, &a)
	e.mu.Lock()
	s := e.sessions[a.Name]
	delete(e.sessions, a.Name)
	e.mu.Unlock()
	if s != nil {
		s.console.Close()
	}
	return map[string]any{"killed": s != nil}, nil
}
func (e *Env) cwd(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct{ Name string }
	_ = json.Unmarshal(raw, &a)
	s := e.get(a.Name)
	if s == nil {
		return nil, wire.Errf(wire.CodeNotFound, "本地终端已结束")
	}
	return map[string]any{"cwd": s.cwd}, nil
}
func (e *Env) attach(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var a struct {
		Name       string
		Cols, Rows int
	}
	if json.Unmarshal(raw, &a) != nil {
		return wire.Errf(wire.CodeBadRequest, "终端参数无效")
	}
	s := e.get(a.Name)
	if s == nil {
		return wire.Errf(wire.CodeNotFound, "本地终端已结束；本地终端不跨 agent 重启恢复")
	}
	if a.Cols > 0 && a.Rows > 0 {
		_ = s.console.Resize(min(a.Cols, 500), min(a.Rows, 300))
	}
	send := func(typ byte, b []byte) error {
		_ = st.SetWriteDeadline(time.Now().Add(20 * time.Second))
		return wire.WriteFrame(st, typ, b)
	}
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return err
	}
	ch := make(chan []byte, 128)
	s.mu.Lock()
	history := append([]byte{}, s.history...)
	s.listeners[ch] = struct{}{}
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.listeners, ch); s.mu.Unlock() }()
	if len(history) > 0 {
		if err := send(wire.TypeData, append([]byte("\x1bc"), history...)); err != nil {
			return err
		}
	}
	ctl := make(chan wire.TerminalControl, 8)
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		defer cancel()
		for {
			typ, b, err := wire.ReadFrame(st)
			if err != nil {
				return
			}
			if typ == wire.TypeData {
				if _, err = s.console.Input.Write(b); err != nil {
					return
				}
			} else if typ == wire.TypeJSON {
				var c wire.TerminalControl
				if json.Unmarshal(b, &c) == nil {
					select {
					case ctl <- c:
					case <-cctx.Done():
						return
					}
				}
			}
		}
	}()
	for {
		select {
		case <-cctx.Done():
			return nil
		case <-s.done:
			return send(wire.TypeJSON, []byte(`{"type":"exit"}`))
		case b, ok := <-ch:
			if !ok {
				return nil
			}
			if err := send(wire.TypeData, b); err != nil {
				return err
			}
		case c := <-ctl:
			switch c.Type {
			case "close":
				return nil
			case "resize":
				if c.Cols > 0 && c.Rows > 0 {
					_ = s.console.Resize(min(c.Cols, 500), min(c.Rows, 300))
				}
			case "ping":
				b, _ := json.Marshal(wire.TerminalControl{Type: "pong", Code: c.Code})
				if err := send(wire.TypeJSON, b); err != nil {
					return err
				}
			}
		}
	}
}
