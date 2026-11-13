package main

import (
	"aurora3/internal/wire"
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"github.com/hashicorp/yamux"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLocalAgentLifecycleAndServices(t *testing.T) {
	if os.Getenv("AURORA_LOCAL_HELPER") == "1" {
		if err := run(); err != nil {
			os.Exit(9)
		}
		os.Exit(0)
	}
	root := t.TempDir()
	state := filepath.Join(root, "state")
	work := filepath.Join(root, "项目 空格")
	if err := os.Mkdir(work, 0700); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, "-test.run=^TestLocalAgentLifecycleAndServices$")
	cmd.Env = append(os.Environ(), "AURORA_LOCAL_HELPER=1")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	if err = json.NewEncoder(input).Encode(map[string]string{"state_dir": state}); err != nil {
		t.Fatal(err)
	}
	var ready struct{ Addr, Pin, Token, Kind, Platform string }
	handshake := make(chan error, 1)
	go func() { handshake <- json.NewDecoder(bufio.NewReader(output)).Decode(&ready) }()
	select {
	case err = <-handshake:
		if err != nil {
			t.Fatal("bootstrap failed", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("bootstrap timeout")
	}
	if !strings.HasPrefix(ready.Addr, "127.0.0.1:") || ready.Kind != "local" || ready.Platform != "windows" {
		t.Fatal("unsafe local bind")
	}
	raw, err := net.DialTimeout("tcp", ready.Addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	conn := tls.Client(raw, wire.PinnedTLS(ready.Pin))
	if err = conn.Handshake(); err != nil {
		t.Fatal(err)
	}
	if err = wire.WriteJSON(conn, wire.Hello{Role: wire.RoleClient, Version: wire.Version, Token: ready.Token, Client: "local-fixture"}); err != nil {
		t.Fatal(err)
	}
	var hello wire.HelloReply
	if err = wire.ReadJSON(conn, &hello); err != nil || !hello.OK {
		t.Fatal("local auth failed")
	}
	mux, err := yamux.Client(conn, wire.MuxConfig())
	if err != nil {
		t.Fatal(err)
	}
	defer mux.Close()
	session := wire.NewMux(mux, nil)
	call := func(op string, args, out any) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := wire.Call(ctx, session, op, args, out); err != nil {
			t.Fatalf("%s: %v", op, err)
		}
	}
	var services struct{ Services []struct{ ID string } }
	call("agent.services", nil, &services)
	seen := map[string]bool{}
	for _, s := range services.Services {
		seen[s.ID] = true
	}
	for _, id := range []string{"files", "git", "terminal", "ai"} {
		if !seen[id] {
			t.Fatal("missing service", id)
		}
	}
	if seen["systemd"] {
		t.Fatal("Linux service exposed locally")
	}
	volume := strings.ToLower(work[:1])
	rel := "/" + filepath.ToSlash(work[3:])
	call("fs.write", map[string]any{"root": volume, "path": rel + "/fixture.txt", "content": "本机 synthetic content", "create": true}, nil)
	var content struct{ Content string }
	call("fs.read", map[string]any{"root": volume, "path": rel + "/fixture.txt"}, &content)
	if content.Content != "本机 synthetic content" {
		t.Fatal("file round trip failed")
	}
	call("fs.write", map[string]any{"root": volume, "path": rel + "/fixture.txt", "content": "updated synthetic content"}, nil)
	call("session.create", map[string]any{"name": "fixture", "root": volume, "path": rel}, nil)
	var sessions struct {
		Persistent bool
		Sessions   []struct{ Name string }
	}
	call("session.list", nil, &sessions)
	if sessions.Persistent || len(sessions.Sessions) != 1 {
		t.Fatal("local terminal lifecycle mismatch")
	}
	// Closing the parent pipe must stop the agent and its terminal job, without SCM.
	_ = input.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(8 * time.Second):
		t.Fatal("local agent survived client exit")
	}
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	_, err = conn.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("connection survived local shutdown")
	}
}
