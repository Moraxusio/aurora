package netproxy

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	hyserver "github.com/apernet/hysteria/core/v2/server"

	"aurora3/internal/wire"
)

// loopbackOutbound lets the Hysteria2 server dial the test's echo server on
// loopback; the library's default outbound does the same, and is kept here
// only to make the dependency of the test explicit.
type hyAuth struct{ password string }

func (a hyAuth) Authenticate(_ net.Addr, auth string, _ uint64) (bool, string) {
	return auth == a.password, "user"
}

// startHy2 runs the Hysteria2 project's own server on a UDP port and returns
// its address and certificate pin. psk, when set, wraps the server's socket in
// Salamander so only a client that obfuscates the same way can talk to it.
func startHy2(t *testing.T, password, psk string) (addr, pin string) {
	t.Helper()
	cert, pin, err := wire.LoadOrCreateCert(t.TempDir(), "hy2")
	if err != nil {
		t.Fatal(err)
	}
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var conn net.PacketConn = pc
	if psk != "" {
		conn = newSalamander(pc, []byte(psk))
	}
	s, err := hyserver.NewServer(&hyserver.Config{
		TLSConfig:     hyserver.TLSConfig{Certificates: []tls.Certificate{cert}},
		Conn:          conn,
		Authenticator: hyAuth{password},
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = s.Serve() }()
	t.Cleanup(func() { _ = s.Close() })
	return pc.LocalAddr().String(), pin
}

func hy2Node(addr, pin, password string) Node {
	n := nodeAt(ProtoHy2, addr)
	n.Secret = password
	n.TLS = TLSMode{Enabled: true, Pin: pin, SNI: "node.example"}
	return n
}

func TestHysteria2Tunnel(t *testing.T) {
	echo := echoServer(t)
	addr, pin := startHy2(t, "correct-horse-battery", "")
	d, err := newDialer(hy2Node(addr, pin, "correct-horse-battery"), 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	echoThrough(t, d, echo, "hello hysteria2")
	echoThrough(t, d, echo, strings.Repeat("h", 200_000))
}

func TestHysteria2WrongPasswordIsRefused(t *testing.T) {
	echo := echoServer(t)
	addr, pin := startHy2(t, "correct-horse-battery", "")
	d, _ := newDialer(hy2Node(addr, pin, "not-the-password"), 3*time.Second, nil)
	defer d.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if c, err := d.DialContext(ctx, echo); err == nil {
		c.Close()
		t.Fatal("a wrong password opened a tunnel")
	}
}

func TestHysteria2ChecksTheCertificate(t *testing.T) {
	echo := echoServer(t)
	addr, pin := startHy2(t, "correct-horse-battery", "")
	try := func(mut func(*Node)) error {
		n := hy2Node(addr, pin, "correct-horse-battery")
		mut(&n)
		d, err := newDialer(n, 3*time.Second, nil)
		if err != nil {
			return err
		}
		defer d.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		c, err := d.DialContext(ctx, echo)
		if err == nil {
			c.Close()
		}
		return err
	}
	if err := try(func(n *Node) {}); err != nil {
		t.Fatalf("the right pin: %v", err)
	}
	if err := try(func(n *Node) { n.TLS.Pin = strings.Repeat("cd", 32) }); err == nil {
		t.Fatal("a wrong pin was accepted")
	}
	// no pin, not insecure: a self-signed certificate must be refused
	if err := try(func(n *Node) { n.TLS.Pin = "" }); err == nil {
		t.Fatal("an unknown certificate was accepted with no pin and no skip")
	}
	if err := try(func(n *Node) { n.TLS.Pin = ""; n.TLS.Insecure = true }); err != nil {
		t.Fatalf("with verification skipped by choice: %v", err)
	}
}

func TestHysteria2Salamander(t *testing.T) {
	echo := echoServer(t)
	addr, pin := startHy2(t, "correct-horse-battery", "obfs-secret")
	n := hy2Node(addr, pin, "correct-horse-battery")
	n.Obfs, n.ObfsPassword = "salamander", "obfs-secret"
	d, err := newDialer(n, 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	echoThrough(t, d, echo, "through salamander")

	// without the obfuscation the server does not answer at all
	plain := hy2Node(addr, pin, "correct-horse-battery")
	d2, _ := newDialer(plain, 2*time.Second, nil)
	defer d2.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if c, err := d2.DialContext(ctx, echo); err == nil {
		c.Close()
		t.Fatal("a client without the obfuscation reached an obfuscated server")
	}
}

// The obfuscation is its own inverse over a socket pair, whatever the packet.
func TestSalamanderRoundTrip(t *testing.T) {
	a, _ := net.ListenPacket("udp", "127.0.0.1:0")
	b, _ := net.ListenPacket("udp", "127.0.0.1:0")
	defer a.Close()
	defer b.Close()
	sa, sb := newSalamander(a, []byte("key1")), newSalamander(b, []byte("key1"))
	for _, n := range []int{1, 7, 100, 1200} {
		msg := []byte(strings.Repeat("x", n))
		if _, err := sa.WriteTo(msg, b.LocalAddr()); err != nil {
			t.Fatal(err)
		}
		_ = sb.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 2000)
		m, from, err := sb.ReadFrom(buf)
		if err != nil || string(buf[:m]) != string(msg) {
			t.Fatalf("size %d: got %d bytes, err %v", n, m, err)
		}
		if from.String() != a.LocalAddr().String() {
			t.Fatalf("from %v, want %v", from, a.LocalAddr())
		}
	}
	// a packet that is only a salt is dropped, not delivered as empty data
	raw, _ := net.ListenPacket("udp", "127.0.0.1:0")
	defer raw.Close()
	_, _ = raw.WriteTo([]byte("12345678"), b.LocalAddr())
	_, _ = sa.WriteTo([]byte("after"), b.LocalAddr())
	_ = sb.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 100)
	m, _, err := sb.ReadFrom(buf)
	if err != nil || string(buf[:m]) != "after" {
		t.Fatalf("after a runt packet: %q %v", buf[:m], err)
	}
}

// A network that drops UDP must fail within the dial's own deadline, so the
// user sees the reason instead of a hung terminal.
func TestHysteria2TimesOutWhenUDPIsDropped(t *testing.T) {
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := udp.LocalAddr().String() // bound but nobody reads: packets vanish
	defer udp.Close()
	d, _ := newDialer(hy2Node(dead, strings.Repeat("ab", 32), "pw-pw-pw-pw"), 2*time.Second, nil)
	defer d.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	start := time.Now()
	_, err = d.DialContext(ctx, "example.org:443")
	if err == nil {
		t.Fatal("a dead server answered")
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Fatalf("took %s to give up", el)
	}
	if !strings.Contains(err.Error(), "UDP") && !strings.Contains(err.Error(), "超时") {
		t.Logf("error: %v", err)
	}
}

var _ = io.EOF
