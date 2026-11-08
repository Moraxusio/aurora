package entry

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/proxysvc"
	"aurora3/internal/service"
	"aurora3/internal/wire"
)

// The proxy service reads and saves its state through the entry, and the entry
// calls its Switched hook while holding the lock those two take. This test
// wires them the way the agent does and switches the service on over the link:
// if the hook ever touches the entry's lock again, the call never returns.
func TestSwitchingTheProxyOnOverTheLinkDoesNotDeadlock(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "agent.json")
	node := `{"node":{"name":"HK","proto":"trojan","host":"127.0.0.1","port":9,"secret":"node-secret-aaaaaaaaaaaa","tls":{"enabled":true,"insecure":true}}}`
	cfg := &Config{Listen: "127.0.0.1:0", Token: testToken, StateDir: filepath.Join(dir, "state"),
		Roots: []Root{{ID: "home", Path: dir}}, Services: map[string]bool{"proxy": false},
		AuditLog: filepath.Join(dir, "audit.log"), Proxy: json.RawMessage(node)}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Save(cfgPath); err != nil {
		t.Fatal(err)
	}

	var srv *Server
	px := &proxysvc.Env{
		Load: func() proxysvc.State {
			var st proxysvc.State
			_ = json.Unmarshal(srv.ProxyRaw(), &st)
			return st
		},
		Save: func(st proxysvc.State) error {
			b, _ := json.Marshal(st)
			return srv.SaveProxyRaw(b)
		},
		Enabled: func() bool { return srv.ServiceEnabled(proxysvc.ID) },
	}
	var err error
	srv, err = New(cfg, cfgPath, "3.0.0-test", []service.Service{px.Service()}, nil, nil, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	px.Start() // the service is off: nothing may come up
	defer px.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := make(chan struct{})
	go func() { _ = srv.Run(ctx, ready) }()
	<-ready
	s, _, err := dial(t, srv.Addr().String(), srv.Pin(), hello())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// off: the operations are refused
	if err := call(t, s, "proxy.status", nil, nil); wire.CodeOf(err) != wire.CodeUnavailable {
		t.Fatalf("service off: %v", err)
	}

	done := make(chan error, 1)
	go func() { done <- call(t, s, "agent.service", map[string]any{"id": "proxy", "enabled": true}, nil) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("agent.service never returned: switching the proxy on deadlocked")
	}

	var st struct {
		Running bool `json:"running"`
		Node    *struct {
			Name string `json:"name"`
		} `json:"node"`
	}
	if err := call(t, s, "proxy.status", nil, &st); err != nil {
		t.Fatal(err)
	}
	if !st.Running || st.Node == nil || st.Node.Name != "HK" {
		t.Fatalf("after switching on: %+v", st)
	}

	// the port and credentials made by the switch are saved to agent.json, by
	// the time the hook's own work (outside the lock) has finished
	deadline := time.Now().Add(3 * time.Second)
	for {
		saved, err := LoadConfig(cfgPath)
		if err != nil {
			t.Fatal(err)
		}
		var ps proxysvc.State
		_ = json.Unmarshal(saved.Proxy, &ps)
		if ps.Port != 0 && ps.Password != "" && ps.Node != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the local port and credentials were not saved: %s", saved.Proxy)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// switching off closes the listener, and a second switch on still works
	for i := 0; i < 2; i++ {
		if err := call(t, s, "agent.service", map[string]any{"id": "proxy", "enabled": false}, nil); err != nil {
			t.Fatal(err)
		}
		if err := call(t, s, "agent.service", map[string]any{"id": "proxy", "enabled": true}, nil); err != nil {
			t.Fatalf("round %d: %v", i, err)
		}
	}
	if err := call(t, s, "proxy.status", nil, &st); err != nil || !st.Running {
		t.Fatalf("after cycling the switch: %+v %v", st, err)
	}
	_ = os.Remove(cfgPath)
}
