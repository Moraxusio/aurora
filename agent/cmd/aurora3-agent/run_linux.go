//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"

	"aurora3/internal/bundle"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	"aurora3/internal/git"
	"aurora3/internal/monitor"
	"aurora3/internal/netfwd"
	"aurora3/internal/proxysvc"
	"aurora3/internal/service"
	"aurora3/internal/systemd"
	"aurora3/internal/terminal"
	"aurora3/internal/upgrade"
)

const defaultConfigPath = entry.DefaultConfigPath

func run(cfgPath string) error {
	cfg, err := entry.LoadConfig(cfgPath)
	if err != nil {
		return err
	}
	logger := log.New(os.Stderr, "", log.LstdFlags)
	audit := entry.NewAudit(cfg.AuditLog)
	// The systemd service reads the allowlist from the running entry, so a change
	// made with agent.actions applies to the next svc.action (D-28).
	var srv *entry.Server
	host := &lateHost{}
	actions := func() map[string][]string { return srv.ServiceActions() }
	list, term, px := services(cfg, audit, actions, host, logger)
	srv, err = entry.New(cfg, cfgPath, Version, list, lookPath, audit, logger)
	if err != nil {
		return err
	}
	host.srv = srv
	// The listener comes up now if the service is on and a node is saved; it
	// stops with the agent.
	px.Start()
	defer px.Close()
	// session.kill belongs to the entry, so it works while terminal is off (D-52).
	if err := srv.AddEntryOp("session.kill", term.KillOp()); err != nil {
		return err
	}
	if err := srv.AddEntryOp("session.proxy", term.ProxyInfoOp()); err != nil {
		return err
	}
	u := &upgrade.Env{StateDir: cfg.StateDir, Version: Version, Arch: runtime.GOARCH, Gate: srv.TransferGate(), Launch: func(dir string) error { return launchUpgrade(cfg.Instance, dir) }}
	for _, op := range u.Operations() {
		if op.Stream != nil {
			err = srv.AddEntryStream(op.Name, op.Stream)
		} else {
			err = srv.AddEntryOp(op.Name, op.Handle)
		}
		if err != nil {
			return err
		}
	}
	ctx, stop := signalContext()
	defer stop()
	return srv.Run(ctx, nil)
}

// services builds the compiled-in service list (D-40, D-45). The audit writer
// is the entry's; proxy is nil until the proxy service exists (G2.8), so git
// runs without proxy variables.
func services(cfg *entry.Config, audit *entry.Audit, actions func() map[string][]string, host proxyHost, logger *log.Logger) ([]service.Service, *terminal.Env, *proxysvc.Env) {
	px := &proxysvc.Env{
		Load: func() proxysvc.State {
			var st proxysvc.State
			_ = json.Unmarshal(host.ProxyRaw(), &st)
			return st
		},
		Save: func(st proxysvc.State) error {
			b, err := json.Marshal(st)
			if err != nil {
				return err
			}
			return host.SaveProxyRaw(b)
		},
		Enabled: func() bool { return host.ServiceEnabled(proxysvc.ID) },
		Audit:   audit,
		Log:     logger,
	}
	// git takes the proxy environment from the service on every call (D-69).
	proxy := px.GitEnv
	fr := make([]files.Root, len(cfg.Roots))
	gr := make([]git.Root, len(cfg.Roots))
	mr := make([]monitor.Root, len(cfg.Roots))
	tr := make([]terminal.Root, len(cfg.Roots))
	for i, r := range cfg.Roots {
		fr[i] = files.Root{ID: r.ID, Label: r.Label, Path: r.Path}
		gr[i] = git.Root{ID: r.ID, Label: r.Label, Path: r.Path}
		mr[i] = monitor.Root{ID: r.ID, Label: r.Label, Path: r.Path}
		tr[i] = terminal.Root{ID: r.ID, Path: r.Path}
	}
	fe := &files.Env{Roots: fr, UploadMaxBytes: cfg.UploadMaxBytes, Audit: audit, Repos: git.Repos{Proxy: proxy}}
	ge := &git.Env{Roots: gr, Audit: audit, Proxy: proxy}
	me := &monitor.Env{Roots: mr, Audit: audit}
	se := &systemd.Env{Actions: actions, Audit: audit}
	ne := &netfwd.Env{}
	lay, _ := entry.LayoutFor(cfg.Instance) // Validate has checked the name
	te := &terminal.Env{StateDir: cfg.StateDir, Socket: lay.Socket, UnitPrefix: lay.TmuxPrefix, Roots: tr, Audit: audit, Bundle: bundle.FS{},
		NoUnit: os.Getenv("INVOCATION_ID") == "", // not started by systemd: no transient units
		Proxy:  px.SessionEnv}
	return []service.Service{fe.Service(), ge.Service(), me.Service(), se.Service(), ne.Service(), px.Service(), te.Service()}, te, px
}

// proxyHost is what the proxy service needs from the entry: the switch, and a
// place to keep its state in agent.json.
type proxyHost interface {
	ServiceEnabled(id string) bool
	ProxyRaw() json.RawMessage
	SaveProxyRaw(json.RawMessage) error
}

// lateHost lets the services be built before the entry exists (the entry takes
// the service list), and points at the entry once it has been made.
type lateHost struct{ srv *entry.Server }

func (h *lateHost) ServiceEnabled(id string) bool { return h.srv != nil && h.srv.ServiceEnabled(id) }
func (h *lateHost) ProxyRaw() json.RawMessage {
	if h.srv == nil {
		return nil
	}
	return h.srv.ProxyRaw()
}
func (h *lateHost) SaveProxyRaw(b json.RawMessage) error {
	if h.srv == nil {
		return errors.New("agent 还没有启动完成")
	}
	return h.srv.SaveProxyRaw(b)
}

func lookPath(name string) error {
	_, err := exec.LookPath(name)
	return err
}

func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
}
