package netproxy

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"aurora3/internal/wire"
)

// Config is the local end: a loopback listener that speaks SOCKS5 and HTTP
// CONNECT, and requires credentials.
type Config struct {
	Listen   string `json:"listen,omitempty"` // default 127.0.0.1
	Port     int    `json:"port,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	// MaxConns caps simultaneous tunnels (0 = 128).
	MaxConns int `json:"max_conns,omitempty"`
	// Timeout bounds the connection and handshake to the node (0 = 10 s).
	Timeout time.Duration `json:"-"`
}

// Env is what sessions need to route their traffic through the proxy.
func (c Config) Env() map[string]string {
	addr := net.JoinHostPort(c.listen(), strconv.Itoa(c.Port))
	cred := ""
	if c.Username != "" {
		cred = url.UserPassword(c.Username, c.Password).String() + "@"
	}
	httpURL := "http://" + cred + addr
	socksURL := "socks5h://" + cred + addr
	noProxy := "127.0.0.1,localhost,::1"
	if hn, err := os.Hostname(); err == nil && hn != "" {
		noProxy += "," + hn
		if i := strings.IndexByte(hn, '.'); i > 0 {
			noProxy += "," + hn[:i]
		}
	}
	return map[string]string{
		"HTTP_PROXY": httpURL, "HTTPS_PROXY": httpURL, "ALL_PROXY": socksURL,
		"http_proxy": httpURL, "https_proxy": httpURL, "all_proxy": socksURL,
		"NO_PROXY": noProxy, "no_proxy": noProxy,
	}
}

// Addr is the local listen address ("127.0.0.1:port").
func (c Config) Addr() string { return net.JoinHostPort(c.listen(), strconv.Itoa(c.Port)) }

func (c Config) listen() string { return orDefault(c.Listen, "127.0.0.1") }

func (c Config) maxConns() int {
	if c.MaxConns > 0 {
		return c.MaxConns
	}
	return 128
}

func (c Config) hasAuth() bool { return c.Username != "" && c.Password != "" }

func (c Config) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 10 * time.Second
}

// Stats is a snapshot of proxy activity. It never carries a secret.
type Stats struct {
	Addr   string `json:"addr"`
	Active int64  `json:"active"`
	Total  int64  `json:"total"`
	Denied int64  `json:"denied"`
	// Failed counts tunnels the node did not open; LastError is the latest reason.
	Failed    int64  `json:"failed"`
	LastError string `json:"last_error,omitempty"`
	// Node is the label of the node in use ("" when none is chosen).
	Node string `json:"node,omitempty"`
}

// Proxy is a running local listener.
type Proxy struct {
	cfg    Config
	ln     net.Listener
	log    *log.Logger
	sem    chan struct{}
	wg     sync.WaitGroup
	closed atomic.Bool

	connMu sync.Mutex
	conns  map[net.Conn]struct{}

	active atomic.Int64
	total  atomic.Int64
	denied atomic.Int64
	failed atomic.Int64

	nodeMu  sync.Mutex
	node    *liveNode
	lastErr string
}

// liveNode is the node tunnels leave through, with the count of tunnels still
// open on it. Replacing the node retires it: it closes once the last of its
// tunnels has ended, so a switch never cuts a download in progress (D-90).
type liveNode struct {
	n       Node
	d       dialer
	mu      sync.Mutex
	open    int
	retired bool
}

func (l *liveNode) acquire() { l.mu.Lock(); l.open++; l.mu.Unlock() }

func (l *liveNode) release() {
	l.mu.Lock()
	l.open--
	done := l.retired && l.open <= 0
	l.mu.Unlock()
	if done {
		l.d.Close()
	}
}

func (l *liveNode) retire() {
	l.mu.Lock()
	l.retired = true
	done := l.open <= 0
	l.mu.Unlock()
	if done {
		l.d.Close()
	}
}

// countedConn releases its node when it is closed, once.
type countedConn struct {
	net.Conn
	l    *liveNode
	once sync.Once
}

func (c *countedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.l.release)
	return err
}

// Start binds the listener and serves until Close. The caller must call Close.
// The listener works as soon as it is up, but a tunnel can only open once a
// node has been chosen with SetNode.
func Start(cfg Config, logger *log.Logger) (*Proxy, error) {
	if cfg.Port == 0 || cfg.Port > 65535 {
		return nil, errors.New("代理端口无效")
	}
	if !cfg.hasAuth() {
		return nil, errors.New("本地代理必须设置用户名和密码")
	}
	if ip := net.ParseIP(cfg.listen()); ip == nil || !ip.IsLoopback() {
		return nil, errors.New("本地代理只能监听回环地址")
	}
	ln, err := net.Listen("tcp", cfg.Addr())
	if err != nil {
		return nil, fmt.Errorf("监听 %s 失败：%w", cfg.Addr(), err)
	}
	p := &Proxy{cfg: cfg, ln: ln, log: logger, sem: make(chan struct{}, cfg.maxConns()), conns: make(map[net.Conn]struct{})}
	go p.accept()
	return p, nil
}

// SetNode makes n the node new tunnels leave through. nil clears it. Tunnels
// already open stay on the node they started on until they end.
func (p *Proxy) SetNode(n *Node) error {
	var next *liveNode
	if n != nil {
		var logf func(string, ...any)
		if p.log != nil {
			logf = p.log.Printf
		}
		d, err := newDialer(*n, p.cfg.timeout(), logf)
		if err != nil {
			return err
		}
		next = &liveNode{n: *n, d: d}
	}
	p.nodeMu.Lock()
	old := p.node
	p.node = next
	p.lastErr = ""
	p.nodeMu.Unlock()
	if old != nil {
		old.retire()
	}
	return nil
}

func (p *Proxy) current() *liveNode {
	p.nodeMu.Lock()
	defer p.nodeMu.Unlock()
	return p.node
}

// Addr reports the bound address.
func (p *Proxy) Addr() string { return p.ln.Addr().String() }

// Env reports the environment sessions should receive.
func (p *Proxy) Env() map[string]string {
	cfg := p.cfg
	cfg.Port = portOf(p.ln.Addr().String())
	return cfg.Env()
}

// Stats returns a snapshot.
func (p *Proxy) Stats() Stats {
	st := Stats{
		Addr:   p.Addr(),
		Active: p.active.Load(),
		Total:  p.total.Load(),
		Denied: p.denied.Load(),
		Failed: p.failed.Load(),
	}
	p.nodeMu.Lock()
	st.LastError = p.lastErr
	if p.node != nil {
		st.Node = p.node.n.Label()
	}
	p.nodeMu.Unlock()
	return st
}

// Close stops accepting and waits for the open tunnels to finish.
func (p *Proxy) Close() error {
	if p.closed.Swap(true) {
		return nil
	}
	err := p.ln.Close()
	_ = p.SetNode(nil)
	p.connMu.Lock()
	for c := range p.conns {
		_ = c.Close()
	}
	p.connMu.Unlock()
	done := make(chan struct{})
	go func() { p.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
	return err
}

func (p *Proxy) accept() {
	for {
		c, err := p.ln.Accept()
		if err != nil {
			if p.closed.Load() {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return
		}
		select {
		case p.sem <- struct{}{}:
		default:
			// Over the cap: refuse rather than queue.
			p.denied.Add(1)
			c.Close()
			continue
		}
		p.wg.Add(1)
		go func() {
			defer func() { <-p.sem; p.wg.Done() }()
			p.serve(c)
		}()
	}
}

func (p *Proxy) track(c net.Conn) func() {
	p.connMu.Lock()
	if p.closed.Load() {
		_ = c.Close()
	} else {
		p.conns[c] = struct{}{}
	}
	p.connMu.Unlock()
	return func() {
		p.connMu.Lock()
		delete(p.conns, c)
		p.connMu.Unlock()
	}
}

func (p *Proxy) serve(c net.Conn) {
	untrack := p.track(c)
	defer untrack()
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	br := bufio.NewReader(c)
	first, err := br.Peek(1)
	if err != nil {
		return
	}
	p.total.Add(1)
	p.active.Add(1)
	defer p.active.Add(-1)

	if first[0] == 0x05 {
		p.serveSocks(c, br)
		return
	}
	p.serveHTTP(c, br)
}

// dial opens a tunnel to target through the node in use. The first reason a
// tunnel could not open is kept for the status, so the user sees "wrong
// password" or "UDP blocked" rather than a bare failure count.
func (p *Proxy) dial(ctx context.Context, target string) (net.Conn, error) {
	l := p.current()
	if l == nil {
		p.failed.Add(1)
		p.nodeMu.Lock()
		p.lastErr = errNoNode.Error()
		p.nodeMu.Unlock()
		return nil, errNoNode
	}
	l.acquire()
	c, err := l.d.DialContext(ctx, target)
	if err != nil {
		l.release()
		p.failed.Add(1)
		p.nodeMu.Lock()
		p.lastErr = err.Error()
		p.nodeMu.Unlock()
		return nil, err
	}
	return &countedConn{Conn: c, l: l}, nil
}

// ---- SOCKS5 (RFC 1928 + RFC 1929 user/password auth) ----

func (p *Proxy) serveSocks(c net.Conn, br *bufio.Reader) {
	ver, err := br.ReadByte()
	if err != nil || ver != 0x05 {
		return
	}
	n, err := br.ReadByte()
	if err != nil {
		return
	}
	methods := make([]byte, n)
	if _, err := io.ReadFull(br, methods); err != nil {
		return
	}
	// Only username/password: an open (0x00) listener is exactly what must not
	// happen on a shared machine.
	ok := false
	for _, m := range methods {
		if m == 0x02 {
			ok = true
		}
	}
	if !ok {
		_, _ = c.Write([]byte{0x05, 0xff})
		p.denied.Add(1)
		return
	}
	if _, err := c.Write([]byte{0x05, 0x02}); err != nil {
		return
	}
	if !p.socksAuth(c, br) {
		p.denied.Add(1)
		return
	}
	host, port, err := readSocksRequest(br)
	if err != nil {
		_, _ = c.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	target := net.JoinHostPort(host, strconv.Itoa(port))
	_ = c.SetDeadline(time.Time{})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	up, err := p.dial(ctx, target)
	if err != nil {
		_, _ = c.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer up.Close()
	untrackUp := p.track(up)
	defer untrackUp()
	if _, err := c.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	// Anything the client sent eagerly after the CONNECT lives in br.
	if n := br.Buffered(); n > 0 {
		b, _ := br.Peek(n)
		if _, err := up.Write(b); err != nil {
			return
		}
		_, _ = br.Discard(n)
	}
	relay(c, up)
}

func (p *Proxy) socksAuth(c net.Conn, br *bufio.Reader) bool {
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil || head[0] != 0x01 {
		return false
	}
	user := make([]byte, head[1])
	if _, err := io.ReadFull(br, user); err != nil {
		return false
	}
	l, err := br.ReadByte()
	if err != nil {
		return false
	}
	pass := make([]byte, l)
	if _, err := io.ReadFull(br, pass); err != nil {
		return false
	}
	if !wire.TokenEqual(string(user), p.cfg.Username) || !wire.TokenEqual(string(pass), p.cfg.Password) {
		_, _ = c.Write([]byte{0x01, 0x01})
		return false
	}
	_, err = c.Write([]byte{0x01, 0x00})
	return err == nil
}

func readSocksRequest(br *bufio.Reader) (string, int, error) {
	head := make([]byte, 4)
	if _, err := io.ReadFull(br, head); err != nil {
		return "", 0, err
	}
	if head[0] != 0x05 || head[1] != 0x01 { // CONNECT only
		return "", 0, errors.New("不支持的命令")
	}
	host, err := readSocksAddr(br, head[3])
	if err != nil {
		return "", 0, err
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(br, pb); err != nil {
		return "", 0, err
	}
	return host, int(pb[0])<<8 | int(pb[1]), nil
}

func readSocksAddr(br *bufio.Reader, atyp byte) (string, error) {
	switch atyp {
	case 0x01:
		b := make([]byte, 4)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", err
		}
		return net.IP(b).String(), nil
	case 0x04:
		b := make([]byte, 16)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", err
		}
		return net.IP(b).String(), nil
	case 0x03:
		l, err := br.ReadByte()
		if err != nil {
			return "", err
		}
		b := make([]byte, l)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", err
		}
		return string(b), nil
	}
	return "", errors.New("地址类型无效")
}

// ---- HTTP proxy (CONNECT and absolute-form requests) ----

// crlf and the status replies are built from bytes so the source never has to
// spell a carriage return.
var (
	crlf        = string([]byte{0x0d, 0x0a})
	emptyLine   = crlf + crlf
	established = "HTTP/1.1 200 Connection Established" + emptyLine
)

func (p *Proxy) serveHTTP(c net.Conn, br *bufio.Reader) {
	line, err := readLine(br, 8<<10)
	if err != nil {
		return
	}
	fields := strings.Fields(line)
	if len(fields) < 3 {
		writeStatus(c, 400, "Bad Request")
		return
	}
	method, target, proto := fields[0], fields[1], fields[2]
	headers, err := readHeaders(br)
	if err != nil {
		return
	}
	if !p.httpAuth(headers) {
		p.denied.Add(1)
		_, _ = fmt.Fprint(c, "HTTP/1.1 407 Proxy Authentication Required"+crlf+
			"Proxy-Authenticate: Basic realm=\"aurora\""+crlf+
			"Content-Length: 0"+crlf+
			"Connection: close"+emptyLine)
		return
	}
	hostport := target
	connect := strings.EqualFold(method, "CONNECT")
	if !connect {
		hostport, err = originAddr(target, headers)
		if err != nil {
			writeStatus(c, 400, "Bad Request")
			return
		}
	}
	if _, _, err := net.SplitHostPort(hostport); err != nil {
		if connect {
			writeStatus(c, 400, "Bad Request")
			return
		}
		hostport = net.JoinHostPort(hostport, "80")
	}
	_ = c.SetDeadline(time.Time{})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	up, err := p.dial(ctx, hostport)
	if err != nil {
		writeStatus(c, 502, "Bad Gateway")
		return
	}
	defer up.Close()
	untrackUp := p.track(up)
	defer untrackUp()

	if connect {
		if _, err := c.Write([]byte(established)); err != nil {
			return
		}
		if n := br.Buffered(); n > 0 {
			b, _ := br.Peek(n)
			if _, err := up.Write(b); err != nil {
				return
			}
			_, _ = br.Discard(n)
		}
		relay(c, up)
		return
	}

	// Plain HTTP: rewrite the request line to origin-form and forward.
	path := originPath(target)
	var b strings.Builder
	b.WriteString(method + " " + path + " " + proto + crlf)
	for _, h := range headers {
		if strings.HasPrefix(strings.ToLower(h), "proxy-") || strings.HasPrefix(strings.ToLower(h), "connection") {
			continue
		}
		b.WriteString(h + crlf)
	}
	b.WriteString("Connection: close" + emptyLine)
	if _, err := up.Write([]byte(b.String())); err != nil {
		return
	}
	if n := br.Buffered(); n > 0 {
		body, _ := br.Peek(n)
		if _, err := up.Write(body); err != nil {
			return
		}
		_, _ = br.Discard(n)
	}
	relay(c, up)
}

func (p *Proxy) httpAuth(headers []string) bool {
	for _, h := range headers {
		name, value, ok := cutHeader(h)
		if !ok || !strings.EqualFold(name, "proxy-authorization") {
			continue
		}
		const prefix = "basic "
		if len(value) <= len(prefix) || !strings.EqualFold(value[:len(prefix)], prefix) {
			return false
		}
		raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value[len(prefix):]))
		if err != nil {
			return false
		}
		user, pass, ok := strings.Cut(string(raw), ":")
		if !ok {
			return false
		}
		return wire.TokenEqual(user, p.cfg.Username) && wire.TokenEqual(pass, p.cfg.Password)
	}
	return false
}

func cutHeader(h string) (string, string, bool) {
	name, value, ok := strings.Cut(h, ":")
	if !ok {
		return "", "", false
	}
	return name, strings.TrimSpace(value), true
}

func readLine(br *bufio.Reader, max int) (string, error) {
	var b strings.Builder
	for b.Len() <= max {
		chunk, isPrefix, err := br.ReadLine()
		if err != nil {
			return "", err
		}
		b.Write(chunk)
		if !isPrefix {
			return b.String(), nil
		}
	}
	return "", errors.New("请求行过长")
}

func readHeaders(br *bufio.Reader) ([]string, error) {
	var out []string
	for i := 0; i < 200; i++ {
		line, err := readLine(br, 16<<10)
		if err != nil {
			return nil, err
		}
		if line == "" {
			return out, nil
		}
		out = append(out, line)
	}
	return out, errors.New("请求头过多")
}

func originAddr(target string, headers []string) (string, error) {
	if u, err := parseAbsolute(target); err == nil {
		return u, nil
	}
	return "", errors.New("需要绝对地址")
}

// parseAbsolute turns "http://host:port/path" into "host:port" (default ports
// filled in).
func parseAbsolute(target string) (string, error) {
	rest, ok := strings.CutPrefix(target, "http://")
	port := "80"
	if !ok {
		rest, ok = strings.CutPrefix(target, "https://")
		port = "443"
	}
	if !ok {
		return "", errors.New("不是绝对地址")
	}
	host := rest
	if i := strings.IndexAny(rest, "/?#"); i >= 0 {
		host = rest[:i]
	}
	if host == "" {
		return "", errors.New("缺少主机")
	}
	if _, _, err := net.SplitHostPort(host); err == nil {
		return host, nil
	}
	return net.JoinHostPort(host, port), nil
}

// originPath keeps only the path and query of an absolute URL.
func originPath(target string) string {
	if i := strings.Index(target, "://"); i >= 0 {
		rest := target[i+3:]
		if j := strings.IndexAny(rest, "/?#"); j >= 0 {
			p := rest[j:]
			if !strings.HasPrefix(p, "/") {
				p = "/" + p
			}
			return p
		}
		return "/"
	}
	return target
}

func writeStatus(c net.Conn, code int, text string) {
	_, _ = fmt.Fprintf(c, "HTTP/1.1 %d %s"+crlf+"Content-Length: 0"+crlf+"Connection: close"+emptyLine, code, text)
}

func portOf(addr string) int {
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(p)
	if err != nil {
		return 0
	}
	return n
}

func orDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}
