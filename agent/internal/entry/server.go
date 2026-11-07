package entry

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hashicorp/yamux"

	"aurora3/internal/p2p"
	"aurora3/internal/paths"
	"aurora3/internal/service"
	"aurora3/internal/wire"
)

// Server is the entry: it owns the identity (certificate, token, id), the
// direct listener and the operation registry.
type Server struct {
	cfg     *Config
	cfgPath string
	version string
	id      string
	cert    tls.Certificate
	pin     string
	log     *log.Logger
	reg     *service.Registry
	audit   *Audit
	started time.Time

	mu    sync.Mutex
	conns map[wire.Session]struct{}
	addr  net.Addr // the bound listener, once Run has started
}

// New loads or creates the identity in cfg.StateDir and builds the registry
// from services. audit is shared with the services (D-26); nil means
// NewAudit(cfg.AuditLog). The entry operations (D-46) are added here.
func New(cfg *Config, cfgPath, version string, services []service.Service, lookPath func(string) error, audit *Audit, logger *log.Logger) (*Server, error) {
	if audit == nil {
		audit = NewAudit(cfg.AuditLog)
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		return nil, err
	}
	cert, pin, err := wire.LoadOrCreateCert(cfg.StateDir, "agent")
	if err != nil {
		return nil, err
	}
	id, err := loadOrCreateID(filepath.Join(cfg.StateDir, "agent-id"))
	if err != nil {
		return nil, err
	}
	reg, err := service.NewRegistry(services, cfg.Services, lookPath)
	if err != nil {
		return nil, err
	}
	s := &Server{cfg: cfg, cfgPath: cfgPath, version: version, id: id, cert: cert, pin: pin, log: logger,
		reg: reg, audit: audit, started: time.Now(), conns: map[wire.Session]struct{}{}}
	for name, h := range map[string]service.Handler{
		"agent.info":     s.agentInfo,
		"agent.health":   s.agentHealth,
		"agent.services": s.agentServices,
		"agent.service":  s.agentSetService,
		"agent.actions":  s.agentActions,
	} {
		if err := reg.AddEntry(name, h); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func loadOrCreateID(path string) (string, error) {
	if b, err := os.ReadFile(path); err == nil && len(strings.TrimSpace(string(b))) >= 16 {
		return strings.TrimSpace(string(b)), nil
	}
	id := wire.NewToken()[:24]
	return id, os.WriteFile(path, []byte(id+"\n"), 0o600)
}

// Pin is the certificate pin clients check.
func (s *Server) Pin() string { return s.pin }

// AddEntryOp registers an operation that belongs to the entry rather than a
// service, so it cannot be switched off (D-46, D-52). Call before Run.
func (s *Server) AddEntryOp(name string, h service.Handler) error { return s.reg.AddEntry(name, h) }

// Audit is the audit writer the services share (D-26).
func (s *Server) AuditLog() *Audit { return s.audit }

// ServiceActions is a copy of the systemd allowlist as it stands now (D-28).
// The systemd service reads it on every call, so a change made with
// agent.actions applies to the next svc.action.
func (s *Server) ServiceActions() map[string][]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string][]string, len(s.cfg.ServiceActions))
	for k, v := range s.cfg.ServiceActions {
		out[k] = append([]string(nil), v...)
	}
	return out
}

// Addr is the bound listener address (nil before Run).
func (s *Server) Addr() net.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addr
}

// Run serves the direct listener until ctx ends. ready, when non-nil, is
// closed once the listener is bound.
func (s *Server) Run(ctx context.Context, ready chan<- struct{}) error {
	tcpLn, err := net.Listen("tcp", s.cfg.Listen)
	if err != nil {
		return err
	}
	ln := tls.NewListener(trackListener{tcpLn}, wire.ServerTLS(s.cert))
	s.mu.Lock()
	s.addr = tcpLn.Addr()
	s.mu.Unlock()
	s.log.Printf("aurora3-agent %s listening on %s (pin %s)", s.version, tcpLn.Addr(), s.pin)
	go func() { <-ctx.Done(); ln.Close() }()
	defer s.audit.Close()
	if ready != nil {
		close(ready)
	}
	lim := wire.NewAcceptLimiter(64, 8, s.log)
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		release := lim.Acquire(c)
		if release == nil {
			_ = c.Close()
			continue
		}
		go func() { defer release(); s.handleDirect(wire.WithAcceptRelease(ctx, release), c) }()
	}
}

// trackListener wraps accepted connections in wire.TrackedConn, below TLS.
type trackListener struct{ net.Listener }

func (l trackListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tuneTCP(c)
	return wire.Track(c), nil
}

func (s *Server) handleDirect(ctx context.Context, c net.Conn) {
	defer c.Close()
	var tc *wire.TrackedConn
	if t, ok := c.(*tls.Conn); ok {
		tc, _ = t.NetConn().(*wire.TrackedConn)
		_ = t.SetDeadline(time.Now().Add(15 * time.Second))
		if err := t.Handshake(); err != nil {
			wire.ReleaseAccept(ctx)
			return
		}
	}
	s.serveClient(ctx, c, tc, "tcp "+c.RemoteAddr().String())
}

// answerHello checks a client's Hello: role, token and protocol major version.
func (s *Server) answerHello(h wire.Hello) wire.HelloReply {
	reply := wire.HelloReply{Version: wire.Version}
	switch {
	case h.Role != wire.RoleClient || !wire.TokenEqual(h.Token, s.cfg.Token):
		reply.Error = "认证失败"
	case !wire.MajorCompatible(h.Version, wire.Version):
		reply.Error = "协议版本不兼容：客户端 " + h.Version + "，服务端 " + wire.Version
	default:
		reply.OK = true
		info := s.Info()
		reply.Server = &info
	}
	return reply
}

func (s *Server) serveClient(ctx context.Context, c net.Conn, tc *wire.TrackedConn, from string) {
	defer wire.ReleaseAccept(ctx)
	done := wire.HandshakeDeadline(c)
	var h wire.Hello
	if err := wire.ReadJSON(c, &h); err != nil {
		return
	}
	reply := s.answerHello(h)
	if err := wire.WriteJSON(c, reply); err != nil || !reply.OK {
		if !reply.OK {
			s.log.Printf("hello rejected from %s: %s", from, reply.Error)
		}
		return
	}
	done()
	ys, err := yamux.Server(c, wire.MuxConfig())
	if err != nil {
		return
	}
	sess := wire.NewMux(ys, tc)
	go wire.KeepChecking(sess, 15*time.Second, nil)
	s.serveSession(ctx, sess)
	if tc != nil && ctx.Err() == nil {
		why := tc.Reason()
		if why == "" {
			why = "会话结束"
		}
		s.log.Printf("%s session ended after %s: %s", from, tc.Age().Round(time.Second), why)
	}
}

func (s *Server) serveSession(ctx context.Context, sess wire.Session) {
	s.mu.Lock()
	s.conns[sess] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.conns, sess)
		s.mu.Unlock()
		sess.Close()
	}()
	go func() {
		select {
		case <-ctx.Done():
		case <-sess.CloseChan():
		}
		sess.Close()
	}()
	for {
		st, err := sess.AcceptStream()
		if err != nil {
			return
		}
		go s.serveStream(ctx, st)
	}
}

const transferIdleTimeout = 2 * time.Minute

// transferConn bounds stalled network I/O without limiting total transfer
// time (v2 server.go): each successful Read or Write permits another interval.
type transferConn struct {
	net.Conn
	idle time.Duration
}

func (c *transferConn) Read(p []byte) (int, error) {
	_ = c.Conn.SetReadDeadline(time.Now().Add(c.idle))
	return c.Conn.Read(p)
}

func (c *transferConn) Write(p []byte) (int, error) {
	_ = c.Conn.SetWriteDeadline(time.Now().Add(c.idle))
	return c.Conn.Write(p)
}

func transferOp(op string) bool { return op == "fs.upload" || op == "fs.download" }

func (s *Server) serveStream(ctx context.Context, st net.Conn) {
	defer st.Close()
	defer func() {
		if r := recover(); r != nil {
			s.log.Printf("panic in op: %v", r)
			_ = wire.WriteJSON(st, wire.ErrResponse(wire.Errf(wire.CodeInternal, "服务端内部错误")))
		}
	}()
	_ = st.SetReadDeadline(time.Now().Add(30 * time.Second))
	var req wire.Request
	if err := wire.ReadJSON(st, &req); err != nil {
		return
	}
	_ = st.SetReadDeadline(time.Time{})
	svcID, stream, err := s.reg.Check(req.Op)
	if err != nil {
		_ = wire.WriteJSON(st, wire.ErrResponse(wireError(req.Op, svcID, err)))
		return
	}
	if !stream {
		cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
		defer cancel()
		res, err := s.reg.Dispatch(cctx, req.Op, req.Args)
		if err != nil {
			_ = wire.WriteJSON(st, wire.ErrResponse(wireError(req.Op, svcID, err)))
			return
		}
		_ = wire.WriteJSON(st, wire.OKResponse(res))
		return
	}
	if transferOp(req.Op) {
		st = &transferConn{Conn: st, idle: transferIdleTimeout}
		stop := context.AfterFunc(ctx, func() { _ = st.Close() })
		defer stop()
	}
	if err := s.reg.DispatchStream(ctx, req.Op, st, req.Args); err != nil && !errors.Is(err, io.EOF) {
		_ = wire.WriteJSON(st, wire.ErrResponse(wireError(req.Op, svcID, err)))
	}
}

// wireError turns registry refusals into the codes clients act on; errors
// from the services already carry their code.
func wireError(op, svcID string, err error) error {
	switch {
	case errors.Is(err, service.ErrUnknown):
		return wire.Errf(wire.CodeUnsupported, "不支持的操作：%s", op)
	case errors.Is(err, service.ErrDisabled):
		return wire.Errf(wire.CodeUnavailable, "服务未启用：%s", svcID)
	case errors.Is(err, service.ErrUnavailable):
		return wire.Errf(wire.CodeUnavailable, "服务不可用：%s", strings.TrimPrefix(err.Error(), service.ErrUnavailable.Error()+": "))
	}
	return err
}

// Info describes this agent to clients (HelloReply.Server). The token is never
// included: clients read it over SSH (D-4).
func (s *Server) Info() wire.AgentInfo {
	host, _ := os.Hostname()
	name := s.cfg.Name
	if name == "" {
		name = host
	}
	var caps []string
	for _, st := range s.reg.Statuses() {
		if st.Enabled && st.Available {
			caps = append(caps, st.Ops...)
		}
	}
	caps = append(caps, s.reg.EntryOps()...)
	sort.Strings(caps)
	port := listenPort(s.cfg.Listen)
	if a, ok := s.Addr().(*net.TCPAddr); ok && port == 0 {
		port = a.Port
	}
	d := wire.DirectInfo{Port: port, Addrs: s.directAddrs(port), CertSHA256: s.pin}
	return wire.AgentInfo{ID: s.id, Name: name, Host: host, OS: osName() + " " + runtime.GOARCH, Version: s.version, Caps: caps, Direct: d}
}

func (s *Server) agentInfo(context.Context, json.RawMessage) (any, error) {
	return map[string]any{"agent": s.Info(), "roots": s.cfg.Roots, "services": s.reg.Statuses()}, nil
}

func (s *Server) agentServices(context.Context, json.RawMessage) (any, error) {
	return map[string]any{"services": s.reg.Statuses()}, nil
}

// agentSetService switches a service and saves the switch to agent.json
// (D-26, D-41). On a save failure the switch is put back.
func (s *Server) agentSetService(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		ID      string `json:"id"`
		Enabled *bool  `json:"enabled"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.ID == "" || a.Enabled == nil {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少服务名或开关值")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	before := s.reg.Enabled(a.ID)
	if err := s.reg.SetEnabled(a.ID, *a.Enabled); err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "未知的服务：%s", a.ID)
	}
	if s.cfgPath != "" {
		next := *s.cfg
		next.Services = map[string]bool{}
		for k, v := range s.cfg.Services {
			next.Services[k] = v
		}
		next.Services[a.ID] = *a.Enabled
		if err := next.Save(s.cfgPath); err != nil {
			_ = s.reg.SetEnabled(a.ID, before)
			return nil, wire.Errf(wire.CodeInternal, "保存配置失败：%v", err)
		}
		s.cfg.Services = next.Services
	}
	s.audit.Write("agent.service", map[string]any{"id": a.ID, "enabled": *a.Enabled})
	return map[string]any{"services": s.reg.Statuses()}, nil
}

// agentActions reads or changes the systemd allowlist (D-28): which of
// start, stop and restart svc.action may run on which unit. Without a name it
// only returns the list. With a name it replaces that unit's actions (an empty
// list removes the unit), saves agent.json, and audits the change like a
// service switch (D-26). On a save failure the list is put back.
func (s *Server) agentActions(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Name    string   `json:"name"`
		Actions []string `json:"actions"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Name == "" {
		return map[string]any{"actions": s.ServiceActions()}, nil
	}
	acts, err := paths.CheckActions(a.Name, a.Actions)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	next := *s.cfg
	next.ServiceActions = map[string][]string{}
	for k, v := range s.cfg.ServiceActions {
		next.ServiceActions[k] = v
	}
	if len(acts) == 0 {
		delete(next.ServiceActions, a.Name)
	} else {
		next.ServiceActions[a.Name] = acts
	}
	if len(next.ServiceActions) == 0 {
		next.ServiceActions = nil
	}
	if s.cfgPath != "" {
		if err := next.Save(s.cfgPath); err != nil {
			return nil, wire.Errf(wire.CodeInternal, "保存配置失败：%v", err)
		}
	}
	s.cfg.ServiceActions = next.ServiceActions
	s.audit.Write("agent.actions", map[string]any{"name": a.Name, "actions": acts})
	out := make(map[string][]string, len(s.cfg.ServiceActions))
	for k, v := range s.cfg.ServiceActions {
		out[k] = append([]string(nil), v...)
	}
	return map[string]any{"actions": out}, nil
}

// agentHealth reports what a long-running agent holds, to spot leaks.
func (s *Server) agentHealth(context.Context, json.RawMessage) (any, error) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fds, _ := os.ReadDir("/proc/self/fd")
	threads := 0
	if b, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "Threads:"); ok {
				threads, _ = strconv.Atoi(strings.TrimSpace(v))
			}
		}
	}
	s.mu.Lock()
	links := len(s.conns)
	s.mu.Unlock()
	return map[string]any{
		"uptime_s": int64(time.Since(s.started).Seconds()), "goroutines": runtime.NumGoroutine(),
		"threads": threads, "fds": len(fds), "heap_bytes": ms.HeapAlloc, "sys_bytes": ms.Sys, "links": links,
	}, nil
}

func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

func listenPort(listen string) int {
	_, p, err := net.SplitHostPort(listen)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(p)
	if err != nil {
		return 0
	}
	return n
}

// directAddrs lists host:port candidates (v2 server.go): configured public
// addresses first, then this machine's usable addresses. A loopback listener
// advertises only itself.
func (s *Server) directAddrs(port int) []string {
	out := append([]string{}, s.cfg.PublicAddrs...)
	if listensLoopback(s.cfg.Listen) {
		if host, _, err := net.SplitHostPort(s.cfg.Listen); err == nil && host != "" {
			out = append(out, net.JoinHostPort(host, strconv.Itoa(port)))
		}
		return dedupe(out)
	}
	out = append(out, p2p.HostPorts(p2p.Addrs(), port, false)...)
	return dedupe(out)
}

func listensLoopback(listen string) bool {
	host, _, err := net.SplitHostPort(listen)
	if err != nil || host == "" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return strings.EqualFold(host, "localhost")
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	out := in[:0]
	for _, v := range in {
		if v != "" && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

func osName() string {
	if b, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				return strings.Trim(v, "\"")
			}
		}
	}
	return runtime.GOOS
}

// Audit appends one JSON line per mutating operation (v2 ops.go auditLog).
type Audit struct {
	path string
	f    *wire.RotatingFile
}

func NewAudit(path string) *Audit {
	return &Audit{path: path, f: &wire.RotatingFile{Path: path, Max: 8 << 20, Mode: 0o600}}
}

func (a *Audit) Write(event string, fields map[string]any) {
	if a == nil || a.path == "" {
		return
	}
	if fields == nil {
		fields = map[string]any{}
	}
	fields["event"] = event
	fields["ts"] = time.Now().UTC().Format(time.RFC3339)
	b, err := json.Marshal(fields)
	if err != nil {
		return
	}
	_, _ = a.f.Write(append(b, '\n'))
}

// Close closes the log file; a later Write reopens it.
func (a *Audit) Close() error {
	if a == nil || a.path == "" {
		return nil
	}
	return a.f.Close()
}
