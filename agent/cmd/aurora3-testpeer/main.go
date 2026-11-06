// aurora3-testpeer runs the real agent entry (pinned TLS, Hello, yamux,
// dispatch) with only the test service, for client tests and benchmarks. It
// is not shipped. It prints one JSON line {"addr","pin","token"} on stdout and
// runs until stdin is closed.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/service"
	"aurora3/internal/testsvc"
	"aurora3/internal/wire"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "listen address")
	off := flag.Bool("test-off", false, "start with the test service switched off")
	verbose := flag.Bool("v", false, "log to stderr")
	state := flag.String("state", "", "keep identity and token in this directory across runs (restart tests); default: a fresh temporary one")
	flag.Parse()
	if err := run(*listen, *off, *verbose, *state); err != nil {
		fmt.Fprintln(os.Stderr, "aurora3-testpeer:", err)
		os.Exit(1)
	}
}

func run(listen string, off, verbose bool, state string) error {
	// Tests kill this process (to check a dead agent), so a deferred removal
	// may never run; leftovers of earlier runs are removed here instead.
	sweepStale()
	dir := state
	if dir == "" {
		d, err := os.MkdirTemp("", "aurora3-testpeer-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(d)
		dir = d
	}
	cfgPath := filepath.Join(dir, "agent.json")
	// With -state the same certificate and token come back after a restart,
	// as on a real server; the config is written once.
	cfg, err := entry.LoadConfig(cfgPath)
	if err != nil {
		cfg = &entry.Config{Listen: listen, Token: wire.NewToken(), StateDir: filepath.Join(dir, "state"),
			Roots: []entry.Root{{ID: "tmp", Path: dir}}}
		if err := cfg.Validate(); err != nil {
			return err
		}
		if err := cfg.Save(cfgPath); err != nil {
			return err
		}
	}
	cfg.Listen = listen
	if off {
		cfg.Services = map[string]bool{testsvc.ID: false}
	}
	out := io.Discard
	if verbose {
		out = os.Stderr
	}
	srv, err := entry.New(cfg, cfgPath, "3.0.0-testpeer", []service.Service{testsvc.Service()}, nil, nil, log.New(out, "testpeer ", log.Lmicroseconds))
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- srv.Run(ctx, ready) }()
	select {
	case <-ready:
	case err := <-done:
		return err
	}
	b, _ := json.Marshal(map[string]string{"addr": srv.Addr().String(), "pin": srv.Pin(), "token": cfg.Token})
	fmt.Println(string(b))
	go func() {
		_, _ = io.Copy(io.Discard, bufio.NewReader(os.Stdin))
		cancel()
	}()
	return <-done
}

// sweepStale removes aurora3-testpeer-* directories in the temp directory
// that are older than an hour: their process is gone (a run lasts seconds).
// Only this tool's own directories match the prefix.
func sweepStale() {
	tmp := os.TempDir()
	ents, err := os.ReadDir(tmp)
	if err != nil {
		return
	}
	for _, e := range ents {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "aurora3-testpeer-") {
			continue
		}
		if fi, err := e.Info(); err == nil && time.Since(fi.ModTime()) > time.Hour {
			_ = os.RemoveAll(filepath.Join(tmp, e.Name()))
		}
	}
}
