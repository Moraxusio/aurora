package entry

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"aurora3/internal/proxysvc"
	"aurora3/internal/service"
)

// Force the exact crossing that used to deadlock: proxy.set owns the proxy
// mutex, then agent.service tries to acquire it while a config save is pending.
func TestConcurrentProxySaveAndSwitch(t *testing.T) {
	dir := t.TempDir()
	cfg := &Config{Token: testToken, StateDir: dir, Roots: []Root{{ID: "home", Path: dir}}}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	enteredSave, allowSave := make(chan struct{}), make(chan struct{})
	var once sync.Once
	var srv *Server
	px := &proxysvc.Env{
		Load: func() proxysvc.State { var st proxysvc.State; _ = json.Unmarshal(srv.ProxyRaw(), &st); return st },
		Save: func(st proxysvc.State) error {
			once.Do(func() { close(enteredSave); <-allowSave })
			raw, _ := json.Marshal(st)
			return srv.SaveProxyRaw(raw)
		},
		Enabled: func() bool { return srv.ServiceEnabled("proxy") },
	}
	var err error
	srv, err = New(cfg, filepath.Join(dir, "agent.json"), "audit", []service.Service{px.Service()}, nil, nil, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	setDone, switchDone := make(chan error, 1), make(chan error, 1)
	go func() {
		_, err := srv.reg.Dispatch(context.Background(), "proxy.set", json.RawMessage(`{"node":{"name":"audit","proto":"trojan","host":"127.0.0.1","port":9,"secret":"synthetic-audit-password","tls":{"enabled":true,"insecure":true}}}`))
		setDone <- err
	}()
	select {
	case <-enteredSave:
	case <-time.After(time.Second):
		t.Fatal("save not reached")
	}
	go func() {
		_, err := srv.agentSetService(context.Background(), json.RawMessage(`{"id":"proxy","enabled":false}`))
		switchDone <- err
	}()
	deadline := time.Now().Add(time.Second)
	for srv.ServiceEnabled("proxy") && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	close(allowSave)
	for _, done := range []chan error{setDone, switchDone} {
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("proxy/config lock inversion")
		}
	}
	px.Close()
	if e := px.GitEnv(); e != nil {
		t.Fatal("disabled proxy still supplies git environment")
	}
	if _, err := px.SessionEnv(); err == nil {
		t.Fatal("disabled proxy offered to a session")
	}
}
