package netproxy

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These tests dial a real Xray server. The fake servers in fakeserver_test.go
// were written from the same reading of the protocol as the dialers, so they
// can agree with a dialer on a mistake; Xray cannot. Set AURORA3_XRAY to the
// path of an xray binary to run them (they are skipped otherwise). The binary
// is not part of Aurora and is not shipped: it only serves the tests.
func xrayBin(t *testing.T) string {
	t.Helper()
	p := os.Getenv("AURORA3_XRAY")
	if p == "" {
		t.Skip("AURORA3_XRAY is not set")
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("no xray at %s", p)
	}
	return p
}

// echoServer answers every connection by sending back what it receives, and
// remembers nothing: Xray's "freedom" outbound dials it for us.
func echoServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()
	return ln.Addr().String()
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

// startXray runs xray with one inbound and the freedom outbound, and waits
// until the inbound accepts connections.
func startXray(t *testing.T, bin string, inbound map[string]any, port int) {
	t.Helper()
	cfg := map[string]any{
		"log":      map[string]any{"loglevel": "debug"},
		"inbounds": []any{inbound},
		// A recent Xray refuses to dial loopback addresses from its freedom
		// outbound; the echo server is on loopback, so allow it explicitly.
		"outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{
			"finalRules": []any{map[string]any{"action": "allow"}},
		}}},
	}
	b, _ := json.Marshal(cfg)
	path := filepath.Join(t.TempDir(), "xray.json")
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, "run", "-c", path)
	var out strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			t.Logf("xray said:\n%s", out.String())
		}
	})
	addr := net.JoinHostPort("127.0.0.1", itoa(port))
	for i := 0; i < 100; i++ {
		if c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
			c.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("xray did not start: %s", out.String())
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func xrayEcho(t *testing.T, n Node, echo string) {
	t.Helper()
	d, err := newDialer(n, 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, echo)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(10 * time.Second))
	for _, msg := range []string{"hello through a real xray", strings.Repeat("z", 100_000)} {
		go func(m string) { _, _ = c.Write([]byte(m)) }(msg)
		got := make([]byte, len(msg))
		if _, err := io.ReadFull(c, got); err != nil {
			t.Fatalf("read %d bytes: %v", len(msg), err)
		}
		if string(got) != msg {
			t.Fatalf("echo differs for a %d byte message", len(msg))
		}
	}
}

func TestXrayVLESS(t *testing.T) {
	bin := xrayBin(t)
	echo := echoServer(t)
	port := freeTCPPort(t)
	startXray(t, bin, map[string]any{
		"listen": "127.0.0.1", "port": port, "protocol": "vless",
		"settings":       map[string]any{"clients": []any{map[string]any{"id": testUUID}}, "decryption": "none"},
		"streamSettings": map[string]any{"network": "tcp"},
	}, port)
	n := Node{Proto: ProtoVLESS, Host: "127.0.0.1", Port: port, Secret: testUUID}
	xrayEcho(t, n, echo)
}

func TestXrayVLESSOverWebSocket(t *testing.T) {
	bin := xrayBin(t)
	echo := echoServer(t)
	port := freeTCPPort(t)
	startXray(t, bin, map[string]any{
		"listen": "127.0.0.1", "port": port, "protocol": "vless",
		"settings": map[string]any{"clients": []any{map[string]any{"id": testUUID}}, "decryption": "none"},
		"streamSettings": map[string]any{
			"network":    "ws",
			"wsSettings": map[string]any{"path": "/tunnel"},
		},
	}, port)
	n := Node{Proto: ProtoVLESS, Host: "127.0.0.1", Port: port, Secret: testUUID, Transport: "ws", WSPath: "/tunnel"}
	xrayEcho(t, n, echo)
}

func TestXrayVMess(t *testing.T) {
	bin := xrayBin(t)
	for _, c := range []string{"auto", "aes-128-gcm", "chacha20-poly1305"} {
		t.Run(c, func(t *testing.T) {
			echo := echoServer(t)
			port := freeTCPPort(t)
			startXray(t, bin, map[string]any{
				"listen": "127.0.0.1", "port": port, "protocol": "vmess",
				"settings":       map[string]any{"clients": []any{map[string]any{"id": testUUID}}},
				"streamSettings": map[string]any{"network": "tcp"},
			}, port)
			n := Node{Proto: ProtoVMess, Host: "127.0.0.1", Port: port, Secret: testUUID, Cipher: c}
			xrayEcho(t, n, echo)
		})
	}
}

func TestXrayVMessOverWebSocket(t *testing.T) {
	bin := xrayBin(t)
	echo := echoServer(t)
	port := freeTCPPort(t)
	startXray(t, bin, map[string]any{
		"listen": "127.0.0.1", "port": port, "protocol": "vmess",
		"settings": map[string]any{"clients": []any{map[string]any{"id": testUUID}}},
		"streamSettings": map[string]any{
			"network":    "ws",
			"wsSettings": map[string]any{"path": "/vm"},
		},
	}, port)
	n := Node{Proto: ProtoVMess, Host: "127.0.0.1", Port: port, Secret: testUUID, Transport: "ws", WSPath: "/vm"}
	xrayEcho(t, n, echo)
}

// Xray must refuse the wrong user, so the tests above are not passing because
// the server lets everybody in.
func TestXrayRefusesAWrongUUID(t *testing.T) {
	bin := xrayBin(t)
	echo := echoServer(t)
	port := freeTCPPort(t)
	startXray(t, bin, map[string]any{
		"listen": "127.0.0.1", "port": port, "protocol": "vmess",
		"settings":       map[string]any{"clients": []any{map[string]any{"id": testUUID}}},
		"streamSettings": map[string]any{"network": "tcp"},
	}, port)
	n := Node{Proto: ProtoVMess, Host: "127.0.0.1", Port: port, Secret: "00000000-0000-4000-8000-000000000000"}
	d, _ := newDialer(n, 3*time.Second, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, echo)
	if err != nil {
		return
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(4 * time.Second))
	_, _ = c.Write([]byte("x"))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("a wrong UUID got an answer from xray")
	}
}
