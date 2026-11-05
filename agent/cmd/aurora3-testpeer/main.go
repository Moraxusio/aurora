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

	"aurora3/internal/entry"
	"aurora3/internal/service"
	"aurora3/internal/testsvc"
	"aurora3/internal/wire"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "listen address")
	off := flag.Bool("test-off", false, "start with the test service switched off")
	verbose := flag.Bool("v", false, "log to stderr")
	flag.Parse()
	if err := run(*listen, *off, *verbose); err != nil {
		fmt.Fprintln(os.Stderr, "aurora3-testpeer:", err)
		os.Exit(1)
	}
}

func run(listen string, off, verbose bool) error {
	dir, err := os.MkdirTemp("", "aurora3-testpeer-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	cfg := &entry.Config{Listen: listen, Token: wire.NewToken(), StateDir: filepath.Join(dir, "state"),
		Roots: []entry.Root{{ID: "tmp", Path: dir}}}
	if off {
		cfg.Services = map[string]bool{testsvc.ID: false}
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	cfgPath := filepath.Join(dir, "agent.json")
	if err := cfg.Save(cfgPath); err != nil {
		return err
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
