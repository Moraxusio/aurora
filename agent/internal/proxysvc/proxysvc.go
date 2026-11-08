// Package proxysvc is the "proxy" service (D-45, D-83 to D-90): a loopback
// proxy on the server that sessions and git leave through, and the node it
// leaves by. The client picks a node (from a subscription it fetched and
// parsed itself, D-84) and sends this agent that one node; the agent never
// sees the subscription.
//
// The node's password is write-only: proxy.set takes it, nothing returns it.
// It is kept in the agent's own config file (0600), as the direct token is.
package proxysvc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"aurora3/internal/netproxy"
	"aurora3/internal/service"
	"aurora3/internal/wire"
)

// ID is the service name in agent.json and on the wire.
const ID = "proxy"

// State is what the agent keeps between runs: the chosen node and the
// credentials of the local listener. It lives in agent.json under "proxy".
type State struct {
	Node *netproxy.Node `json:"node,omitempty"`
	// Port, Username and Password are the local listener's. They are made on
	// first use and are never shown to a client.
	Port     int    `json:"port,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
}

// Auditor records one line per change (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// Env is everything the proxy service needs from the agent.
type Env struct {
	// Load returns the saved state; Save stores it (the entry writes agent.json).
	Load func() State
	Save func(State) error
	// Enabled reports the service switch. Callers ask it every time, so a switch
	// changed at run time applies to the next session and the next git call (D-69).
	Enabled func() bool
	Audit   Auditor
	Log     *log.Logger

	mu    sync.Mutex
	proxy *netproxy.Proxy
	// pendingSave holds credentials made while saving was not allowed.
	pendingSave *State
}

func (e *Env) audit(event string, f map[string]any) {
	if e.Audit != nil {
		e.Audit.Write(event, f)
	}
}

// Service returns the proxy service.
func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string                         { return ID }
func (svc) Dependencies() []service.Dependency { return nil }

func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "proxy.status", Handle: e.status},
		{Name: "proxy.set", Handle: e.set},
		{Name: "proxy.clear", Handle: e.clear},
		{Name: "proxy.test", Handle: e.test},
		{Name: "proxy.check", Handle: e.check},
	}
}

// Switched stops the listener when the service goes off and starts it again
// when it comes back on (D-53): sessions already running keep the variables
// they started with, and find the port closed.
//
// The registry calls Switched while the entry holds the lock that saving the
// config also takes (agent.service), so nothing here may save the config
// before it returns. Turning the service on therefore starts the listener
// from what is already saved, and a listener that needs a new port or
// credentials gets them saved afterwards, outside that lock.
func (v svc) Switched(on bool) {
	e := v.e
	e.mu.Lock()
	defer e.mu.Unlock()
	if !on {
		e.stopLocked()
		return
	}
	saved := e.Save
	e.Save = nil
	err := e.startLocked()
	e.Save = saved
	if err != nil {
		if e.Log != nil {
			e.Log.Printf("代理服务启动失败：%v", err)
		}
		return
	}
	if e.pendingSave != nil && saved != nil {
		st := *e.pendingSave
		e.pendingSave = nil
		go func() { _ = saved(st) }()
	}
}

// Start brings the listener up if the service is on and a node is saved.
// Call it once after the agent has loaded its config.
func (e *Env) Start() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.Enabled != nil && !e.Enabled() {
		return
	}
	if err := e.startLocked(); err != nil && e.Log != nil {
		e.Log.Printf("代理服务启动失败：%v", err)
	}
}

// Close stops the listener when the agent stops.
func (e *Env) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.stopLocked()
}

func (e *Env) stopLocked() {
	if e.proxy != nil {
		_ = e.proxy.Close()
		e.proxy = nil
	}
}

// startLocked starts the listener when a node is saved. Without a node there
// is nothing to listen for: sessions asking for a proxy are told to choose one.
func (e *Env) startLocked() error {
	if e.proxy != nil {
		return nil
	}
	st := e.Load()
	if st.Node == nil {
		return nil
	}
	return e.listenLocked(&st)
}

func (e *Env) listenLocked(st *State) error {
	changed := false
	if st.Username == "" || st.Password == "" {
		st.Username, st.Password = "aurora", randomHex(16)
		changed = true
	}
	for try := 0; try < 8; try++ {
		if st.Port == 0 {
			st.Port = randomPort()
			changed = true
		}
		var lg *log.Logger = e.Log
		if lg == nil {
			lg = log.New(discard{}, "", 0)
		}
		p, err := netproxy.Start(netproxy.Config{Listen: "127.0.0.1", Port: st.Port, Username: st.Username, Password: st.Password}, lg)
		if err != nil {
			if isAddrInUse(err) {
				st.Port, changed = 0, true // someone took it: pick another
				continue
			}
			return err
		}
		if err := p.SetNode(st.Node); err != nil {
			_ = p.Close()
			return err
		}
		e.proxy = p
		if changed {
			if e.Save == nil {
				cp := *st
				e.pendingSave = &cp
				return nil
			}
			if err := e.Save(*st); err != nil {
				_ = p.Close()
				e.proxy = nil
				return fmt.Errorf("保存代理配置失败：%w", err)
			}
		}
		return nil
	}
	return errors.New("找不到空闲的本机端口")
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func isAddrInUse(err error) bool {
	var ne *net.OpError
	return errors.As(err, &ne) && (containsFold(err.Error(), "address already in use") || containsFold(err.Error(), "only one usage"))
}

func containsFold(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if equalFold(s[i:i+len(sub)], sub) {
			return true
		}
	}
	return false
}

func equalFold(a, b string) bool {
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 'a' - 'A'
		}
		if y >= 'A' && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// randomPort picks a port between 20000 and 31999: above the ports services
// usually take and below Linux's ephemeral range (32768 and up), so outgoing
// connections do not use it by accident. If something already listens there,
// listenLocked tries another.
func randomPort() int {
	var b [2]byte
	_, _ = rand.Read(b[:])
	return 20000 + (int(b[0])<<8|int(b[1]))%12000
}

// SessionEnv is the variables a new session needs (D-47 to D-50). It refuses
// with the reason when the service is off or no node is chosen, so a session
// that asked for a proxy never starts without one.
func (e *Env) SessionEnv() (map[string]string, error) {
	if e.Enabled != nil && !e.Enabled() {
		return nil, errors.New("代理服务已关闭，请先打开它")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxy == nil {
		if err := e.startLocked(); err != nil {
			return nil, fmt.Errorf("代理没有启动：%v", err)
		}
	}
	if e.proxy == nil {
		return nil, errors.New("还没有选择代理节点：请先在代理页选一个节点")
	}
	return e.proxy.Env(), nil
}

// GitEnv is the variables for a git call (D-69). Unlike a session, git
// without a proxy is fine, so a service that is off or has no node gives nil
// rather than an error.
func (e *Env) GitEnv() map[string]string {
	if e.Enabled != nil && !e.Enabled() {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxy == nil {
		return nil
	}
	return e.proxy.Env()
}

// ---- operations ----

func decode(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

// nodeView is what proxy.status says about the chosen node. It has no secret.
type nodeView struct {
	Name      string `json:"name,omitempty"`
	Proto     string `json:"proto"`
	Host      string `json:"host"`
	Port      int    `json:"port"`
	Transport string `json:"transport,omitempty"`
	Verify    string `json:"verify"` // "ca", "pin" or "none": how the certificate is checked
}

func viewOf(n *netproxy.Node) *nodeView {
	if n == nil {
		return nil
	}
	v := &nodeView{Name: n.Name, Proto: n.Proto, Host: n.Host, Port: n.Port, Transport: n.Transport, Verify: "ca"}
	switch {
	case n.TLS.Pin != "":
		v.Verify = "pin"
	case n.TLS.Insecure:
		v.Verify = "none"
	case !n.TLS.Enabled:
		v.Verify = "no-tls"
	}
	return v
}

func (e *Env) status(context.Context, json.RawMessage) (any, error) {
	st := e.Load()
	e.mu.Lock()
	defer e.mu.Unlock()
	out := map[string]any{"enabled": e.Enabled == nil || e.Enabled(), "node": viewOf(st.Node), "running": e.proxy != nil}
	if e.proxy != nil {
		s := e.proxy.Stats()
		out["active"], out["total"], out["failed"] = s.Active, s.Total, s.Failed
		if s.LastError != "" {
			out["last_error"] = s.LastError
		}
	}
	return out, nil
}

type setArgs struct {
	Node netproxy.Node `json:"node"`
}

func (e *Env) set(_ context.Context, raw json.RawMessage) (any, error) {
	var a setArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := a.Node.Check(); err != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	st := e.Load()
	prev := st
	st.Node = &a.Node
	if e.Save != nil {
		if err := e.Save(st); err != nil {
			return nil, wire.Errf(wire.CodeInternal, "保存代理配置失败：%v", err)
		}
	}
	// The listener may not be up yet (first node, or the service was off).
	if e.proxy != nil {
		if err := e.proxy.SetNode(&a.Node); err != nil {
			if e.Save != nil {
				_ = e.Save(prev)
			}
			return nil, wire.Errf(wire.CodeBadRequest, "%v", err)
		}
	} else if e.Enabled == nil || e.Enabled() {
		if err := e.listenLocked(&st); err != nil {
			if e.Save != nil {
				_ = e.Save(prev)
			}
			return nil, wire.Errf(wire.CodeUnavailable, "代理没有启动：%v", err)
		}
	}
	e.audit("proxy.set", map[string]any{"node": a.Node.Label(), "proto": a.Node.Proto})
	return map[string]any{"node": viewOf(&a.Node)}, nil
}

func (e *Env) clear(context.Context, json.RawMessage) (any, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	st := e.Load()
	st.Node = nil
	if e.Save != nil {
		if err := e.Save(st); err != nil {
			return nil, wire.Errf(wire.CodeInternal, "保存代理配置失败：%v", err)
		}
	}
	// With no node there is nothing to listen for. A listener left up would
	// still hand sessions and git proxy variables that lead nowhere: a session
	// that asked for a proxy would start without a working one (D-49), and git
	// would fail on every call instead of going direct (D-69).
	e.stopLocked()
	e.audit("proxy.clear", nil)
	return map[string]any{"node": nil}, nil
}

// check says, for each node of a list, whether this agent can use it and if
// not why. It dials nothing. The client asks before it lets the user choose, so
// the rules for what is usable live here and nowhere else.
func (e *Env) check(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Nodes []netproxy.Node `json:"nodes"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if len(a.Nodes) > 5000 {
		return nil, wire.Errf(wire.CodeBadRequest, "节点太多")
	}
	reasons := make([]string, len(a.Nodes))
	for i, n := range a.Nodes {
		if err := n.Check(); err != nil {
			reasons[i] = err.Error()
		}
	}
	return map[string]any{"reasons": reasons}, nil
}

type testArgs struct {
	// Node, when set, is tried instead of the chosen one: the client uses it to
	// test every node of a subscription from this server before one is chosen
	// (D-84). Nothing is saved.
	Node   *netproxy.Node `json:"node,omitempty"`
	Target string         `json:"target,omitempty"` // host:port to open through the node
}

// test opens one tunnel through a node and reports how long it took. It is the
// only measurement of a node that means anything: it is made from this server.
func (e *Env) test(ctx context.Context, raw json.RawMessage) (any, error) {
	var a testArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	target := a.Target
	if target == "" {
		target = "www.gstatic.com:80"
	}
	var n *netproxy.Node
	if a.Node != nil {
		n = a.Node
	} else {
		n = e.Load().Node
	}
	if n == nil {
		return nil, wire.Errf(wire.CodeBadRequest, "还没有选择代理节点")
	}
	cctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	start := time.Now()
	err := netproxy.Probe(cctx, *n, target)
	ms := time.Since(start).Milliseconds()
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error(), "ms": ms}, nil
	}
	return map[string]any{"ok": true, "ms": ms}, nil
}
