package proxysvc

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"aurora3/internal/netproxy"
	"aurora3/internal/wire"
)

const nodeSecret = "node-password-9f31c0aa77d2"

// A Trojan node that echoes, standing in for the airport's server.
type fakeNode struct {
	ln     net.Listener
	mu     sync.Mutex
	target string
}

func startNode(t *testing.T, secret string) *fakeNode {
	t.Helper()
	cert, _, err := wire.LoadOrCreateCert(t.TempDir(), "n")
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeNode{ln: ln}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				br := bufio.NewReader(c)
				pw := make([]byte, 58)
				if _, err := io.ReadFull(br, pw); err != nil {
					return
				}
				if !strings.HasPrefix(string(pw), trojanHash(secret)) {
					return
				}
				head := make([]byte, 2)
				if _, err := io.ReadFull(br, head); err != nil || head[0] != 1 {
					return
				}
				var host string
				switch head[1] {
				case 3:
					l, _ := br.ReadByte()
					b := make([]byte, l)
					io.ReadFull(br, b)
					host = string(b)
				case 1:
					b := make([]byte, 4)
					io.ReadFull(br, b)
					host = net.IP(b).String()
				default:
					return
				}
				pb := make([]byte, 2)
				io.ReadFull(br, pb)
				io.ReadFull(br, make([]byte, 2))
				f.mu.Lock()
				f.target = fmt.Sprintf("%s:%d", host, int(pb[0])<<8|int(pb[1]))
				f.mu.Unlock()
				_, _ = io.Copy(c, br)
			}()
		}
	}()
	return f
}

func (f *fakeNode) got() string { f.mu.Lock(); defer f.mu.Unlock(); return f.target }

func (f *fakeNode) node() netproxy.Node {
	host, ps, _ := net.SplitHostPort(f.ln.Addr().String())
	var port int
	fmt.Sscan(ps, &port)
	return netproxy.Node{Name: "Test HK 01", Proto: netproxy.ProtoTrojan, Host: host, Port: port, Secret: nodeSecret,
		TLS: netproxy.TLSMode{Enabled: true, Insecure: true}}
}

type rec struct {
	mu sync.Mutex
	ev []string
}

func (r *rec) Write(event string, f map[string]any) {
	b, _ := json.Marshal(f)
	r.mu.Lock()
	r.ev = append(r.ev, event+" "+string(b))
	r.mu.Unlock()
}
func (r *rec) all() string { r.mu.Lock(); defer r.mu.Unlock(); return strings.Join(r.ev, "\n") }

// store is what the entry's agent.json is in the agent: a file, written and read back.
type store struct {
	path string
	on   bool
}

func (s *store) Load() State {
	var st State
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}
func (s *store) Save(st State) error {
	b, _ := json.Marshal(st)
	return os.WriteFile(s.path, b, 0o600)
}

func newEnv(t *testing.T) (*Env, *store, *rec) {
	t.Helper()
	s := &store{path: filepath.Join(t.TempDir(), "proxy.json"), on: true}
	r := &rec{}
	e := &Env{Load: s.Load, Save: s.Save, Enabled: func() bool { return s.on }, Audit: r}
	t.Cleanup(e.Close)
	return e, s, r
}

func call(t *testing.T, e *Env, op string, args any) (map[string]any, error) {
	t.Helper()
	raw, _ := json.Marshal(args)
	for _, o := range e.Service().Operations() {
		if o.Name != op {
			continue
		}
		v, err := o.Handle(context.Background(), raw)
		if err != nil {
			return nil, err
		}
		b, _ := json.Marshal(v)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		return m, nil
	}
	t.Fatalf("no operation %s", op)
	return nil, nil
}

// get fetches an http URL through the agent's local proxy using the variables a session gets.
func proxiedGetStatus(t *testing.T, vars map[string]string, target string) error {
	t.Helper()
	pu, err := url.Parse(vars["HTTP_PROXY"])
	if err != nil {
		t.Fatal(err)
	}
	cl := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: http.ProxyURL(pu), DisableKeepAlives: true}}
	resp, err := cl.Get(target)
	if err != nil {
		return err
	}
	resp.Body.Close()
	// The proxy answers 502 when it cannot open the tunnel (no node, or the
	// node refused). That is a failure to reach the target, not a success.
	if resp.StatusCode == http.StatusBadGateway {
		return fmt.Errorf("the proxy could not open the tunnel (502)")
	}
	return nil
}

func TestChoosingANodeStartsTheProxyAndASessionGetsIt(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, s, au := newEnv(t)

	// nothing chosen: a session that wants a proxy is told what to do
	if _, err := e.SessionEnv(); err == nil || !strings.Contains(err.Error(), "节点") {
		t.Fatalf("no node: %v", err)
	}
	if e.GitEnv() != nil {
		t.Fatal("git got proxy variables with no node chosen")
	}

	if _, err := call(t, e, "proxy.set", map[string]any{"node": node.node()}); err != nil {
		t.Fatal(err)
	}
	vars, err := e.SessionEnv()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(vars["HTTP_PROXY"], "http://aurora:") || !strings.HasPrefix(vars["ALL_PROXY"], "socks5h://") {
		t.Fatalf("variables: %v", vars)
	}
	if g := e.GitEnv(); g == nil || g["HTTPS_PROXY"] != vars["HTTPS_PROXY"] {
		t.Fatalf("git env %v differs from the session's %v", g, vars)
	}

	// the traffic really leaves through the node: a program using the variables
	// asks for a name, and the node is the one that sees it
	_ = proxiedGetStatus(t, vars, "http://one.example/") // the echo node answers with its own request bytes
	if got := node.got(); got != "one.example:80" {
		t.Fatalf("the node was asked for %q", got)
	}

	// the choice is on disk, so it is still there after a restart
	if s.Load().Node == nil || s.Load().Node.Name != "Test HK 01" {
		t.Fatalf("saved state %+v", s.Load())
	}
	if !strings.Contains(au.all(), "proxy.set") {
		t.Fatalf("no audit line: %s", au.all())
	}
}

// The node's password is write-only: nothing the agent says back, logs or
// audits contains it. It is on disk (as the token is), in a 0600 file.
func TestTheNodeSecretNeverComesBack(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, s, au := newEnv(t)
	res, err := call(t, e, "proxy.set", map[string]any{"node": node.node()})
	if err != nil {
		t.Fatal(err)
	}
	st, _ := call(t, e, "proxy.status", nil)
	tst, _ := call(t, e, "proxy.test", nil)
	for name, v := range map[string]any{"set reply": res, "status": st, "test": tst} {
		b, _ := json.Marshal(v)
		if strings.Contains(string(b), nodeSecret) {
			t.Fatalf("%s carries the node's password: %s", name, b)
		}
	}
	if strings.Contains(au.all(), nodeSecret) {
		t.Fatalf("the audit log carries the node's password: %s", au.all())
	}
	// the local listener's password is not in the status either
	local := s.Load().Password
	if local == "" {
		t.Fatal("no local password was made")
	}
	for _, v := range []any{res, st} {
		b, _ := json.Marshal(v)
		if strings.Contains(string(b), local) {
			t.Fatalf("a reply carries the local proxy's password: %s", b)
		}
	}
	// Windows has no permission bits to check; the file mode is the agent's
	// (entry.Config.Save writes 0600) and is checked on Linux.
	if runtime.GOOS != "windows" {
		if fi, err := os.Stat(s.path); err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("state file: %v %v", fi, err)
		}
	}
}

// D-49 and D-69: switching the service off stops sessions and git from getting
// the proxy and closes the port; switching it on brings it back.
func TestTheSwitchDecidesSessionsAndGit(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, s, _ := newEnv(t)
	if _, err := call(t, e, "proxy.set", map[string]any{"node": node.node()}); err != nil {
		t.Fatal(err)
	}
	vars, _ := e.SessionEnv()
	addr := strings.TrimSuffix(strings.TrimPrefix(strings.SplitN(vars["HTTP_PROXY"], "@", 2)[1], ""), "/")

	s.on = false
	e.Service().(interface{ Switched(bool) }).Switched(false)
	if _, err := e.SessionEnv(); err == nil || !strings.Contains(err.Error(), "关闭") {
		t.Fatalf("service off: %v", err)
	}
	if e.GitEnv() != nil {
		t.Fatal("git still gets the proxy with the service off")
	}
	if c, err := net.DialTimeout("tcp", addr, 300*time.Millisecond); err == nil {
		c.Close()
		t.Fatal("the local port is still open with the service off")
	}

	s.on = true
	e.Service().(interface{ Switched(bool) }).Switched(true)
	vars2, err := e.SessionEnv()
	if err != nil {
		t.Fatalf("service on again: %v", err)
	}
	if e.GitEnv() == nil {
		t.Fatal("git does not get the proxy after switching on")
	}
	// the same local credentials: sessions made before keep working
	if vars2["HTTP_PROXY"] != vars["HTTP_PROXY"] {
		t.Fatalf("the local proxy changed across a switch: %q -> %q", vars["HTTP_PROXY"], vars2["HTTP_PROXY"])
	}
}

// Another node can be chosen while the proxy runs; clearing it stops tunnels.
func TestChangingAndClearingTheNode(t *testing.T) {
	a, b := startNode(t, nodeSecret), startNode(t, nodeSecret)
	e, _, _ := newEnv(t)
	call(t, e, "proxy.set", map[string]any{"node": a.node()})
	vars, _ := e.SessionEnv()
	_ = proxiedGetStatus(t, vars, "http://first.example/")
	call(t, e, "proxy.set", map[string]any{"node": b.node()})
	vars2, _ := e.SessionEnv()
	if vars2["HTTP_PROXY"] != vars["HTTP_PROXY"] {
		t.Fatal("choosing another node changed the local proxy")
	}
	_ = proxiedGetStatus(t, vars2, "http://second.example/")
	if a.got() != "first.example:80" || b.got() != "second.example:80" {
		t.Fatalf("first node saw %q, second saw %q", a.got(), b.got())
	}
	call(t, e, "proxy.clear", nil)
	if err := proxiedGetStatus(t, vars2, "http://third.example/"); err == nil {
		t.Fatal("a tunnel opened with no node chosen")
	}
	st, _ := call(t, e, "proxy.status", nil)
	if st["node"] != nil {
		t.Fatalf("status still shows a node: %v", st["node"])
	}
}

// A node the agent cannot dial is refused when it is set, with a reason the
// user can act on, and nothing is saved or changed.
func TestARefusedNodeChangesNothing(t *testing.T) {
	good := startNode(t, nodeSecret)
	e, s, _ := newEnv(t)
	call(t, e, "proxy.set", map[string]any{"node": good.node()})
	before := s.Load()

	bad := good.node()
	bad.Proto, bad.Flow, bad.Secret = netproxy.ProtoVLESS, "xtls-rprx-vision", "b831381d-6324-4d53-ad4f-8cda48b30811"
	_, err := call(t, e, "proxy.set", map[string]any{"node": bad})
	if err == nil || !strings.Contains(err.Error(), "Vision") {
		t.Fatalf("error %v should name the unsupported flow", err)
	}
	after := s.Load()
	if after.Node.Proto != before.Node.Proto || after.Port != before.Port {
		t.Fatalf("a refused node changed the saved state: %+v -> %+v", before, after)
	}
}

func TestProxyTestMeasuresFromThisMachine(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, _, _ := newEnv(t)
	// a node that is not chosen can be tested without choosing it
	res, err := call(t, e, "proxy.test", map[string]any{"node": node.node(), "target": "probe.example:80"})
	if err != nil {
		t.Fatal(err)
	}
	if res["ms"] == nil {
		t.Fatalf("no timing: %v", res)
	}
	if node.got() != "probe.example:80" {
		t.Fatalf("the node was asked for %q", node.got())
	}
	st, _ := call(t, e, "proxy.status", nil)
	if st["node"] != nil {
		t.Fatal("testing a node chose it")
	}
	// a dead node reports why, and does not take long
	dead := node.node()
	dead.Port = 1
	start := time.Now()
	res, _ = call(t, e, "proxy.test", map[string]any{"node": dead})
	if res["ok"] != false || res["error"] == "" {
		t.Fatalf("a dead node: %v", res)
	}
	if time.Since(start) > 10*time.Second {
		t.Fatal("the test of a dead node took too long")
	}
}

// With nothing saved the first node picks a port and credentials; they are
// saved so a restart uses the same ones, and a port that is taken is replaced.
func TestLocalPortIsSavedAndASeizedPortIsReplaced(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, s, _ := newEnv(t)
	call(t, e, "proxy.set", map[string]any{"node": node.node()})
	st := s.Load()
	if st.Port < 20000 || st.Port >= 32000 || len(st.Password) < 24 || st.Username == "" {
		t.Fatalf("saved credentials %+v", st)
	}
	e.Close()

	// take the saved port, then start again from the same file
	hold, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", st.Port))
	if err != nil {
		t.Skipf("could not take the port to test replacement: %v", err)
	}
	defer hold.Close()
	e2 := &Env{Load: s.Load, Save: s.Save, Enabled: func() bool { return true }}
	defer e2.Close()
	e2.Start()
	vars, err := e2.SessionEnv()
	if err != nil {
		t.Fatalf("after the port was taken: %v", err)
	}
	if strings.Contains(vars["HTTP_PROXY"], fmt.Sprintf(":%d", st.Port)) {
		t.Fatal("it kept the port that was taken")
	}
	if s.Load().Port == st.Port {
		t.Fatal("the new port was not saved")
	}
}

func TestStartRestoresTheSavedNode(t *testing.T) {
	node := startNode(t, nodeSecret)
	e, s, _ := newEnv(t)
	call(t, e, "proxy.set", map[string]any{"node": node.node()})
	vars, _ := e.SessionEnv()
	e.Close()

	e2 := &Env{Load: s.Load, Save: s.Save, Enabled: func() bool { return true }}
	defer e2.Close()
	e2.Start()
	vars2, err := e2.SessionEnv()
	if err != nil {
		t.Fatal(err)
	}
	if vars2["HTTP_PROXY"] != vars["HTTP_PROXY"] {
		t.Fatalf("a restart changed the local proxy: %q -> %q", vars["HTTP_PROXY"], vars2["HTTP_PROXY"])
	}
	_ = proxiedGetStatus(t, vars2, "http://after-restart.example/")
	if node.got() != "after-restart.example:80" {
		t.Fatalf("the restored node saw %q", node.got())
	}
}
