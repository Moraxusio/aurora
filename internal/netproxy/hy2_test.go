package netproxy

import (
	"io"
	"log"
	"net"
	"strings"
	"testing"
	"time"
)

// A network that drops UDP must not cost more than one failed attempt: the
// first tunnel falls back to Trojan, later ones skip Hysteria2 while it is
// marked down.
func TestFallsBackToTrojanWithoutUDP(t *testing.T) {
	ft := newFakeTrojan(t, "0123456789abcdef0123")
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := udp.LocalAddr().String()
	udp.Close() // nothing answers there now

	cfg := Config{Listen: "127.0.0.1", Port: freePort(t), Username: "user", Password: "0123456789abcdef",
		Upstream: Upstream{
			Endpoints: []Endpoint{{Addr: ft.ln.Addr().String(), Secret: "0123456789abcdef0123"}}, Insecure: true,
			Hy2: &Hy2{Addr: dead, Password: "0123456789abcdef0123", Pin: strings.Repeat("ab", 32)},
		}}
	p, err := Start(cfg, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()

	for i, limit := range []time.Duration{12 * time.Second, 2 * time.Second} {
		start := time.Now()
		c, err := socksConnect(t, p.Addr(), "user", "0123456789abcdef", "example.org:80")
		if err != nil {
			t.Fatalf("tunnel %d: %v", i, err)
		}
		if _, err := c.Write([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, 4)
		if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "ping" {
			t.Fatalf("tunnel %d echo: %q %v", i, buf, err)
		}
		c.Close()
		if d := time.Since(start); d > limit {
			t.Fatalf("tunnel %d took %s, want under %s", i, d, limit)
		}
	}
	if st := p.Stats(); st.ViaTrojan != 2 || st.ViaHy2 != 0 {
		t.Fatalf("stats %+v", st)
	}
}

func TestHy2NeedsAPin(t *testing.T) {
	if (&Hy2{Addr: "[::1]:443", Password: "0123456789abcdef0123"}).Valid() {
		t.Fatal("an unpinned Hysteria2 upstream must not be used")
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}
