//go:build linux

package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"aurora3/internal/bundle"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	"aurora3/internal/git"
	"aurora3/internal/monitor"
	"aurora3/internal/service"
	"aurora3/internal/systemd"
	"aurora3/internal/terminal"
)

const defaultConfigPath = entry.DefaultConfigPath

func run(cfgPath string) error {
	cfg, err := entry.LoadConfig(cfgPath)
	if err != nil {
		return err
	}
	logger := log.New(os.Stderr, "", log.LstdFlags)
	audit := entry.NewAudit(cfg.AuditLog)
	list, term := services(cfg, audit)
	srv, err := entry.New(cfg, cfgPath, Version, list, lookPath, audit, logger)
	if err != nil {
		return err
	}
	// session.kill belongs to the entry, so it works while terminal is off (D-52).
	if err := srv.AddEntryOp("session.kill", term.KillOp()); err != nil {
		return err
	}
	ctx, stop := signalContext()
	defer stop()
	return srv.Run(ctx, nil)
}

// services builds the compiled-in service list (D-40, D-45). The audit writer
// is the entry's; proxy is nil until the proxy service exists (G2.8), so git
// runs without proxy variables.
func services(cfg *entry.Config, audit *entry.Audit) ([]service.Service, *terminal.Env) {
	var proxy func() map[string]string
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
	se := &systemd.Env{ServiceActions: cfg.ServiceActions, Audit: audit}
	te := &terminal.Env{StateDir: cfg.StateDir, Roots: tr, Audit: audit, Bundle: bundle.FS{},
		NoUnit: os.Getenv("INVOCATION_ID") == ""} // not started by systemd: no transient units
	return []service.Service{fe.Service(), ge.Service(), me.Service(), se.Service(), te.Service()}, te
}

func lookPath(name string) error {
	_, err := exec.LookPath(name)
	return err
}

func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
}
