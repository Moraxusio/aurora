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
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hashicorp/yamux"

	"aurora3/internal/service"
	"aurora3/internal/wire"
)

const testToken = "0123456789abcdef0123456789abcdef"

// echoSvc has one unary and one stream operation, so dispatch, switches and
// streams can be tested without a Linux service.
type echoSvc struct{}

func (echoSvc) ID() string                         { return "echo" }
func (echoSvc) Dependencies() []service.Dependency { return nil }
func (echoSvc) Operations() []service.Operation {
	return []service.Operation{
		{Name: "echo.say", Handle: func(_ context.Context, raw json.RawMessage) (any, error) {
			var a struct {
				Text string `json:"text"`
			}
			if err := decode(raw, &a); err != nil {
				return nil, err
			}
			if a.Text == "fail" {
				return nil, wire.Errf(wire.CodeConflict, "冲突")
			}
			return map[string]string{"text": a.Text}, nil
		}},
		// echo.pipe answers with a Response, then echoes data frames back
		// until 'E' (the shape of fs.upload/terminal streams).
		{Name: "echo.pipe", Stream: func(_ context.Context, st net.Conn, _ json.RawMessage) error {
			if err := wire.WriteJSON(st, wire.OKResponse(nil)); err != nil {
				return err
			}
			for {
				typ, p, err := wire.ReadFrame(st)
				if err != nil {
					return err
				}
				if typ == wire.TypeEnd {
					return wire.WriteFrame(st, wire.TypeEnd, nil)
				}
				if err := wire.WriteFrame(st, typ, p); err != nil {
					return err
				}
			}
		}},
	}
}

type testAgent struct {
	srv     *Server
	addr    string
	cfgPath string
	cancel  context.CancelFunc
	done    chan error
}

func startAgent(t *testing.T, services map[string]bool) *testAgent {
	t.Helper()
	dir := t.TempDir()
	cfg := &Config{Listen: "127.0.0.1:0", Token: testToken, StateDir: filepath.Join(dir, "state"),
		Roots: []Root{{ID: "home", Path: dir}}, Services: services, AuditLog: filepath.Join(dir, "audit.log")}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(dir, "agent.json")
	if err := cfg.Save(cfgPath); err != nil {
		t.Fatal(err)
	}
	srv, err := New(cfg, cfgPath, "3.0.0-test", []service.Service{echoSvc{}}, nil, nil, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan struct{})
	a := &testAgent{srv: srv, cfgPath: cfgPath, cancel: cancel, done: make(chan error, 1)}
	go func() { a.done <- srv.Run(ctx, ready) }()
	select {
	case <-ready:
	case err := <-a.done:
		t.Fatalf("agent did not start: %v", err)
	}
	a.addr = srv.Addr().String()
	t.Cleanup(func() {
		cancel()
		select {
		case <-a.done:
		case <-time.After(5 * time.Second):
			t.Error("agent did not stop")
		}
	})
	return a
}

// dial is the v2 client's path (internal/client/links.go): TCP, pinned TLS,
// Hello, then yamux.
func dial(t *testing.T, addr, pin string, h wire.Hello) (*yamux.Session, wire.HelloReply, error) {
	t.Helper()
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c := tls.Client(raw, wire.PinnedTLS(pin))
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if err := c.Handshake(); err != nil {
		raw.Close()
		return nil, wire.HelloReply{}, err
	}
	if err := wire.WriteJSON(c, h); err != nil {
		c.Close()
		return nil, wire.HelloReply{}, err
	}
	var reply wire.HelloReply
	if err := wire.ReadJSON(c, &reply); err != nil {
		c.Close()
		return nil, reply, err
	}
	if !reply.OK {
		c.Close()
		return nil, reply, errors.New(reply.Error)
	}
	_ = c.SetDeadline(time.Time{})
	s, err := yamux.Client(c, wire.MuxConfig())
	if err != nil {
		c.Close()
		return nil, reply, err
	}
	return s, reply, nil
}

func hello() wire.Hello {
	return wire.Hello{Role: wire.RoleClient, Token: testToken, Version: wire.Version, Client: "test"}
}

func call(t *testing.T, s *yamux.Session, op string, args, out any) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return wire.Call(ctx, wire.NewMux(s, nil), op, args, out)
}

func TestHelloAndUnaryCall(t *testing.T) {
	a := startAgent(t, nil)
	s, reply, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if reply.Version != wire.Version || reply.Server == nil || reply.Server.Direct.CertSHA256 != a.srv.Pin() {
		t.Fatalf("reply %+v", reply)
	}
	if reply.Server.Direct.Token != "" {
		t.Fatal("HelloReply must not carry the token (D-4)")
	}
	var out struct{ Text string }
	if err := call(t, s, "echo.say", map[string]string{"text": "你好"}, &out); err != nil || out.Text != "你好" {
		t.Fatalf("echo.say: %q %v", out.Text, err)
	}
	err = call(t, s, "echo.say", map[string]string{"text": "fail"}, nil)
	if wire.CodeOf(err) != wire.CodeConflict || err.Error() != "冲突" {
		t.Fatalf("service error lost its code: %v (%s)", err, wire.CodeOf(err))
	}
}

func TestWrongTokenRefused(t *testing.T) {
	a := startAgent(t, nil)
	h := hello()
	h.Token = strings.Repeat("x", 32)
	if _, reply, err := dial(t, a.addr, a.srv.Pin(), h); err == nil || reply.Error != "认证失败" {
		t.Fatalf("wrong token: reply %+v err %v", reply, err)
	}
}

func TestWrongPinRefusedBeforeHello(t *testing.T) {
	a := startAgent(t, nil)
	_, _, err := dial(t, a.addr, wire.NewToken(), hello())
	if err == nil || !errors.Is(err, wire.ErrPinMismatch) && !strings.Contains(err.Error(), wire.ErrPinMismatch.Error()) {
		t.Fatalf("wrong pin: %v", err)
	}
}

func TestOtherMajorVersionRefused(t *testing.T) {
	a := startAgent(t, nil)
	h := hello()
	h.Version = "2.0"
	if _, reply, err := dial(t, a.addr, a.srv.Pin(), h); err == nil || !strings.Contains(reply.Error, "协议版本不兼容") {
		t.Fatalf("v2 client: reply %+v err %v", reply, err)
	}
}

func TestUnknownOperation(t *testing.T) {
	a := startAgent(t, nil)
	s, _, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := call(t, s, "echo.nope", nil, nil); wire.CodeOf(err) != wire.CodeUnsupported {
		t.Fatalf("unknown op: %v (%s)", err, wire.CodeOf(err))
	}
}

// A service switched off in agent.json refuses its operations; switching it
// on over the link works at once, is saved to agent.json and audited (D-26,
// D-41, D-44).
func TestServiceSwitchOverTheLink(t *testing.T) {
	a := startAgent(t, map[string]bool{"echo": false})
	s, reply, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, c := range reply.Server.Caps {
		if c == "echo.say" {
			t.Fatal("a disabled service's operations must not be reported as caps")
		}
	}
	err = call(t, s, "echo.say", map[string]string{"text": "x"}, nil)
	if wire.CodeOf(err) != wire.CodeUnavailable || !strings.Contains(err.Error(), "服务未启用") {
		t.Fatalf("disabled: %v (%s)", err, wire.CodeOf(err))
	}
	if err := call(t, s, "agent.service", map[string]any{"id": "echo", "enabled": true}, nil); err != nil {
		t.Fatal(err)
	}
	if err := call(t, s, "echo.say", map[string]string{"text": "x"}, nil); err != nil {
		t.Fatalf("after switching on: %v", err)
	}
	saved, err := LoadConfig(a.cfgPath)
	if err != nil || !saved.Services["echo"] {
		t.Fatalf("switch not saved: %+v %v", saved, err)
	}
	b, _ := os.ReadFile(filepath.Join(filepath.Dir(a.cfgPath), "audit.log"))
	if !strings.Contains(string(b), `"event":"agent.service"`) {
		t.Fatalf("switch not audited: %s", b)
	}
	if err := call(t, s, "agent.service", map[string]any{"id": "nope", "enabled": true}, nil); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("unknown service: %v", err)
	}
}

// agent.actions edits the systemd allowlist over the link (D-28): saved to
// agent.json, audited, visible to the services at once, validated, and
// available with every service off (D-46).
func TestAgentActionsAllowlist(t *testing.T) {
	a := startAgent(t, map[string]bool{"echo": false})
	s, _, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var out struct {
		Actions map[string][]string `json:"actions"`
	}
	if err := call(t, s, "agent.actions", nil, &out); err != nil || len(out.Actions) != 0 {
		t.Fatalf("empty list: %+v %v", out, err)
	}
	if err := call(t, s, "agent.actions", map[string]any{"name": "nginx.service", "actions": []string{"stop", "restart", "stop"}}, &out); err != nil {
		t.Fatal(err)
	}
	if got := out.Actions["nginx.service"]; len(got) != 2 || got[0] != "restart" || got[1] != "stop" {
		t.Fatalf("after set: %+v", out.Actions)
	}
	if got := a.srv.ServiceActions()["nginx.service"]; len(got) != 2 {
		t.Fatalf("services do not see the change: %v", got)
	}
	saved, err := LoadConfig(a.cfgPath)
	if err != nil || len(saved.ServiceActions["nginx.service"]) != 2 {
		t.Fatalf("not saved: %+v %v", saved, err)
	}
	b, _ := os.ReadFile(filepath.Join(filepath.Dir(a.cfgPath), "audit.log"))
	if !strings.Contains(string(b), `"event":"agent.actions"`) {
		t.Fatalf("not audited: %s", b)
	}
	for _, bad := range []map[string]any{
		{"name": "nginx.service", "actions": []string{"enable"}},
		{"name": "-x", "actions": []string{"start"}},
		{"name": "a b", "actions": []string{"start"}},
	} {
		if err := call(t, s, "agent.actions", bad, nil); wire.CodeOf(err) != wire.CodeBadRequest {
			t.Fatalf("%v: %v", bad, err)
		}
	}
	if got := a.srv.ServiceActions()["nginx.service"]; len(got) != 2 {
		t.Fatalf("a refused change altered the list: %v", got)
	}
	// an empty list removes the unit (decode into a fresh map: JSON merges into an old one)
	out.Actions = nil
	if err := call(t, s, "agent.actions", map[string]any{"name": "nginx.service", "actions": []string{}}, &out); err != nil || len(out.Actions) != 0 {
		t.Fatalf("remove: %+v %v", out, err)
	}
	if saved, _ := LoadConfig(a.cfgPath); len(saved.ServiceActions) != 0 {
		t.Fatalf("removal not saved: %+v", saved.ServiceActions)
	}
}

// Entry operations stay available with every service off (D-46).
func TestEntryOperationsAlwaysOn(t *testing.T) {
	a := startAgent(t, map[string]bool{"echo": false})
	s, _, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var info struct {
		Agent    wire.AgentInfo   `json:"agent"`
		Services []service.Status `json:"services"`
	}
	if err := call(t, s, "agent.info", nil, &info); err != nil {
		t.Fatal(err)
	}
	if len(info.Services) != 1 || info.Services[0].ID != "echo" || info.Services[0].Enabled {
		t.Fatalf("services %+v", info.Services)
	}
	var health map[string]any
	if err := call(t, s, "agent.health", nil, &health); err != nil || health["links"].(float64) < 1 {
		t.Fatalf("health %v %v", health, err)
	}
}

// A stream operation keeps its stream: data frames go both ways, and many
// streams run at once on one session.
func TestConcurrentStreams(t *testing.T) {
	a := startAgent(t, nil)
	s, _, err := dial(t, a.addr, a.srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			st, err := s.OpenStream()
			if err != nil {
				errs <- err
				return
			}
			defer st.Close()
			if err := wire.WriteRequest(st, "echo.pipe", nil); err != nil {
				errs <- err
				return
			}
			var r wire.Response
			if err := wire.ReadJSON(st, &r); err != nil || !r.OK {
				errs <- errors.New("no OK response")
				return
			}
			chunk := make([]byte, 64<<10)
			for j := range chunk {
				chunk[j] = byte(i + j)
			}
			for k := 0; k < 32; k++ {
				if err := wire.WriteFrame(st, wire.TypeData, chunk); err != nil {
					errs <- err
					return
				}
				typ, p, err := wire.ReadFrame(st)
				if err != nil || typ != wire.TypeData || len(p) != len(chunk) || p[100] != chunk[100] {
					errs <- errors.New("echo mismatch")
					return
				}
			}
			_ = wire.WriteFrame(st, wire.TypeEnd, nil)
			if typ, _, err := wire.ReadFrame(st); err != nil || typ != wire.TypeEnd {
				errs <- errors.New("no end frame")
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}

// A unary op called as a stream, and the other way round, is refused cleanly.
func TestStreamKindChecked(t *testing.T) {
	r, err := service.NewRegistry([]service.Service{echoSvc{}}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Dispatch(context.Background(), "echo.pipe", nil); !errors.Is(err, service.ErrUnknown) {
		t.Fatalf("stream op as unary: %v", err)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if err := r.DispatchStream(context.Background(), "echo.say", a, nil); !errors.Is(err, service.ErrUnknown) {
		t.Fatalf("unary op as stream: %v", err)
	}
}

func TestConfigDefaultsAreV3Names(t *testing.T) {
	c := &Config{Token: testToken, Roots: []Root{{ID: "r", Path: t.TempDir()}}}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":17710" || c.StateDir != "/var/lib/aurora3" || DefaultConfigPath != "/etc/aurora3/agent.json" {
		t.Fatalf("defaults %q %q %q collide with v2 or changed (D-71)", c.Listen, c.StateDir, DefaultConfigPath)
	}
}
