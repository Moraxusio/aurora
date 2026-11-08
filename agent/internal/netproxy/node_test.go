package netproxy

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

const testUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

func echoThrough(t *testing.T, d dialer, target string, msg string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, target)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(8 * time.Second))
	if _, err := c.Write([]byte(msg)); err != nil {
		t.Fatalf("write: %v", err)
	}
	got := make([]byte, len(msg))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != msg {
		t.Fatalf("echo %q, want %q", got, msg)
	}
}

func TestVLESSOverTCP(t *testing.T) {
	f := listenTCP(t)
	id, _ := parseUUID(testUUID)
	go f.accept(serveVLESS(f, id))
	n := nodeAt(ProtoVLESS, f.addr())
	n.Secret = testUUID
	d, err := newDialer(n, 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	echoThrough(t, d, "example.org:443", "hello vless")
	if got := f.got(); got != "example.org:443" {
		t.Fatalf("server saw target %q", got)
	}
	// an IPv4 and an IPv6 destination travel in their own address forms
	echoThrough(t, d, "203.0.113.9:8080", "x")
	if got := f.got(); got != "203.0.113.9:8080" {
		t.Fatalf("ipv4 target %q", got)
	}
	echoThrough(t, d, "[2001:db8::1]:443", "x")
	if got := f.got(); got != "[2001:db8::1]:443" {
		t.Fatalf("ipv6 target %q", got)
	}
}

func TestVLESSWrongUUIDIsRefused(t *testing.T) {
	f := listenTCP(t)
	id, _ := parseUUID(testUUID)
	go f.accept(serveVLESS(f, id))
	n := nodeAt(ProtoVLESS, f.addr())
	n.Secret = "00000000-0000-4000-8000-000000000000"
	d, _ := newDialer(n, 3*time.Second, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, "example.org:443")
	if err == nil {
		defer c.Close()
		_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
		if _, err = c.Read(make([]byte, 1)); err == nil {
			t.Fatal("a wrong UUID got an answer")
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.rejects == 0 {
		t.Fatal("the server never saw the wrong UUID")
	}
}

func TestVLESSOverTLSChecksTheCertificate(t *testing.T) {
	f, pin := listenTLS(t)
	id, _ := parseUUID(testUUID)
	go f.accept(serveVLESS(f, id))
	base := nodeAt(ProtoVLESS, f.addr())
	base.Secret = testUUID
	base.TLS = TLSMode{Enabled: true, SNI: "node.example"}

	// 1. no pin and not insecure: the self-signed certificate must be refused
	d, _ := newDialer(base, 3*time.Second, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	if c, err := d.DialContext(ctx, "example.org:443"); err == nil {
		c.Close()
		t.Fatal("an unknown certificate was accepted with no pin and no skip")
	}
	cancel()

	// 2. the right pin: accepted
	pinned := base
	pinned.TLS.Pin = pin
	d, _ = newDialer(pinned, 3*time.Second, nil)
	echoThrough(t, d, "example.org:443", "pinned")

	// 3. a different pin: refused
	wrong := base
	wrong.TLS.Pin = strings.Repeat("ab", 32)
	d, _ = newDialer(wrong, 3*time.Second, nil)
	ctx, cancel = context.WithTimeout(context.Background(), 4*time.Second)
	if c, err := d.DialContext(ctx, "example.org:443"); err == nil {
		c.Close()
		t.Fatal("a certificate with another pin was accepted")
	}
	cancel()

	// 4. the user chose to skip verification: accepted
	skip := base
	skip.TLS.Insecure = true
	d, _ = newDialer(skip, 3*time.Second, nil)
	echoThrough(t, d, "example.org:443", "skip")
}

func TestVMessBothCiphers(t *testing.T) {
	for _, cipherName := range []string{"auto", "aes-128-gcm", "chacha20-poly1305"} {
		t.Run(cipherName, func(t *testing.T) {
			f := listenTCP(t)
			id, _ := parseUUID(testUUID)
			go f.accept(serveVMess(f, id, time.Now))
			n := nodeAt(ProtoVMess, f.addr())
			n.Secret, n.Cipher = testUUID, cipherName
			d, err := newDialer(n, 5*time.Second, nil)
			if err != nil {
				t.Fatal(err)
			}
			echoThrough(t, d, "example.org:443", "hello vmess")
			if got := f.got(); got != "example.org:443" {
				t.Fatalf("server saw target %q", got)
			}
			// more than one chunk, and a size that is not a multiple of anything
			big := strings.Repeat("0123456789abcdef", 3000) + "tail"
			echoThrough(t, d, "203.0.113.9:80", big)
			if got := f.got(); got != "203.0.113.9:80" {
				t.Fatalf("ipv4 target %q", got)
			}
		})
	}
}

func TestVMessWrongUUIDIsRefused(t *testing.T) {
	f := listenTCP(t)
	id, _ := parseUUID(testUUID)
	go f.accept(serveVMess(f, id, time.Now))
	n := nodeAt(ProtoVMess, f.addr())
	n.Secret = "00000000-0000-4000-8000-000000000000"
	d, _ := newDialer(n, 3*time.Second, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, "example.org:443")
	if err != nil {
		return
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = c.Write([]byte("x"))
	_, err = c.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("a wrong UUID got an answer")
	}
	if !strings.Contains(err.Error(), "UUID") && !strings.Contains(err.Error(), "握手") {
		t.Logf("error text: %v", err)
	}
}

// A VMess request carries the client's clock; a server refuses one that is
// more than two minutes off. The failure must say so.
func TestVMessClockSkewIsExplained(t *testing.T) {
	f := listenTCP(t)
	id, _ := parseUUID(testUUID)
	go f.accept(serveVMess(f, id, func() time.Time { return time.Now().Add(10 * time.Minute) }))
	n := nodeAt(ProtoVMess, f.addr())
	n.Secret = testUUID
	d, _ := newDialer(n, 3*time.Second, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	c, err := d.DialContext(ctx, "example.org:443")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = c.Write([]byte("x"))
	_, err = c.Read(make([]byte, 1))
	if err == nil || !strings.Contains(err.Error(), "时间") {
		t.Fatalf("a clock-skew refusal should mention the time, got %v", err)
	}
}

func TestNodeCheckRefusesWhatItCannotDo(t *testing.T) {
	ok := Node{Proto: ProtoVLESS, Host: "h", Port: 443, Secret: testUUID, TLS: TLSMode{Enabled: true}}
	if err := ok.Check(); err != nil {
		t.Fatalf("a plain VLESS node was refused: %v", err)
	}
	cases := []struct {
		name string
		mod  func(*Node)
		want string
	}{
		{"vision flow", func(n *Node) { n.Flow = "xtls-rprx-vision" }, "Vision"},
		{"grpc transport", func(n *Node) { n.Transport = "grpc" }, "grpc"},
		{"bad uuid", func(n *Node) { n.Secret = "not-a-uuid" }, "UUID"},
		{"no port", func(n *Node) { n.Port = 0 }, "端口"},
		{"unknown protocol", func(n *Node) { n.Proto = "tuic" }, "tuic"},
		{"bad pin length", func(n *Node) { n.TLS.Pin = "abcd" }, "64"},
	}
	for _, c := range cases {
		n := ok
		c.mod(&n)
		err := n.Check()
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: error %v, want it to mention %q", c.name, err, c.want)
		}
	}
	// Trojan and Hysteria2 are TLS by definition
	if err := (Node{Proto: ProtoTrojan, Host: "h", Port: 443, Secret: "x"}).Check(); err == nil {
		t.Error("a Trojan node without TLS was accepted")
	}
	if err := (Node{Proto: ProtoVMess, Host: "h", Port: 443, Secret: testUUID, Cipher: "rc4"}).Check(); err == nil {
		t.Error("an unsupported VMess cipher was accepted")
	}
	if err := (Node{Proto: ProtoHy2, Host: "h", Port: 443, Secret: "x", Obfs: "other", TLS: TLSMode{Enabled: true}}).Check(); err == nil {
		t.Error("an unknown Hysteria2 obfuscation was accepted")
	}
}

// A secret must never appear in anything the node reports about itself.
func TestNodeLabelHasNoSecret(t *testing.T) {
	n := Node{Name: "HK 01", Proto: ProtoVLESS, Host: "h", Port: 443, Secret: testUUID}
	if strings.Contains(n.Label(), testUUID) {
		t.Fatalf("label leaks the secret: %q", n.Label())
	}
}

// Replacing the node leaves a tunnel that is already open on the old one.
func TestSwitchingNodeKeepsOpenTunnels(t *testing.T) {
	a := newFakeTrojan(t, "0123456789abcdef0123456789abcdef")
	b := newFakeTrojan(t, "fedcba9876543210fedcba9876543210")
	p, cfg := startProxy(t, a.ln.Addr().String(), "0123456789abcdef0123456789abcdef")

	c, err := socksConnect(t, p.Addr(), cfg.Username, cfg.Password, "one.example:443")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := p.SetNode(trojanNode(t, b.ln.Addr().String(), "fedcba9876543210fedcba9876543210")); err != nil {
		t.Fatal(err)
	}
	// the open tunnel still works, and still reaches the first server
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte("still")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 5)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "still" {
		t.Fatalf("open tunnel after switch: %q %v", buf, err)
	}
	// a new tunnel uses the second server
	c2, err := socksConnect(t, p.Addr(), cfg.Username, cfg.Password, "two.example:443")
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	_, _ = c2.Write([]byte("x"))
	_, _ = io.ReadFull(c2, make([]byte, 1))
	time.Sleep(50 * time.Millisecond)
	if a.target != "one.example:443" || b.target != "two.example:443" {
		t.Fatalf("targets: first %q second %q", a.target, b.target)
	}
}

func TestNoNodeRefusesTunnels(t *testing.T) {
	a := newFakeTrojan(t, "0123456789abcdef0123456789abcdef")
	p, cfg := startProxy(t, a.ln.Addr().String(), "0123456789abcdef0123456789abcdef")
	if err := p.SetNode(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := socksConnect(t, p.Addr(), cfg.Username, cfg.Password, "x.example:443"); err == nil {
		t.Fatal("a tunnel opened with no node chosen")
	}
	if st := p.Stats(); st.Node != "" || st.Failed == 0 {
		t.Fatalf("stats %+v", st)
	}
}

func TestStatsReportTheFailureReason(t *testing.T) {
	dead := listenTCP(t)
	addr := dead.addr()
	dead.ln.Close() // nothing listens now
	n := nodeAt(ProtoTrojan, addr)
	n.Secret = "0123456789abcdef"
	n.TLS = TLSMode{Enabled: true, Insecure: true}
	p, cfg := startProxy(t, addr, "0123456789abcdef")
	if err := p.SetNode(&n); err != nil {
		t.Fatal(err)
	}
	if _, err := socksConnect(t, p.Addr(), cfg.Username, cfg.Password, "x.example:443"); err == nil {
		t.Fatal("a tunnel opened through a dead node")
	}
	st := p.Stats()
	if st.LastError == "" || st.Failed == 0 {
		t.Fatalf("no reason kept: %+v", st)
	}
	if strings.Contains(st.LastError, n.Secret) {
		t.Fatalf("error text leaks the secret: %q", st.LastError)
	}
}

// Keep the compiler honest about the helpers the tests above share.
var _ = tls.VersionTLS12
var _ = net.IPv4len
var _ = wire.Version
