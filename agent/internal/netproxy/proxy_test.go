package netproxy

import (
	"bufio"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

// fakeTrojan accepts a Trojan handshake, records the requested target and then
// echoes everything back, so tests never touch the network.
type fakeTrojan struct {
	ln     net.Listener
	secret string
	target string
	auth   string
}

func newFakeTrojan(t *testing.T, secret string) *fakeTrojan {
	t.Helper()
	cert, _, err := wire.LoadOrCreateCert(t.TempDir(), "trojan")
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeTrojan{ln: ln, secret: secret}
	t.Cleanup(func() { ln.Close() })
	go f.serve()
	return f
}

func (f *fakeTrojan) serve() {
	for {
		c, err := f.ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			br := bufio.NewReader(c)
			pw := make([]byte, 58) // hex(sha224) + CRLF
			if _, err := io.ReadFull(br, pw); err != nil {
				return
			}
			if strings.TrimSuffix(string(pw), "\r\n") != trojanPassword(f.secret) {
				return
			}
			head := make([]byte, 2) // command, address type
			if _, err := io.ReadFull(br, head); err != nil || head[0] != 0x01 {
				return
			}
			var host string
			switch head[1] {
			case 0x01:
				b := make([]byte, 4)
				if _, err := io.ReadFull(br, b); err != nil {
					return
				}
				host = net.IP(b).String()
			case 0x04:
				b := make([]byte, 16)
				if _, err := io.ReadFull(br, b); err != nil {
					return
				}
				host = net.IP(b).String()
			case 0x03:
				l, err := br.ReadByte()
				if err != nil {
					return
				}
				b := make([]byte, l)
				if _, err := io.ReadFull(br, b); err != nil {
					return
				}
				host = string(b)
			default:
				return
			}
			pb := make([]byte, 2)
			if _, err := io.ReadFull(br, pb); err != nil {
				return
			}
			if _, err := io.ReadFull(br, make([]byte, 2)); err != nil { // trailing CRLF
				return
			}
			f.target = fmt.Sprintf("%s:%d", host, int(pb[0])<<8|int(pb[1]))
			_, _ = io.Copy(c, br)
		}()
	}
}

// trojanNode is a Node for a server at addr (host:port) with TLS verification off:
// the fake presents a throwaway certificate.
func trojanNode(t *testing.T, addr, secret string) *Node {
	t.Helper()
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatal(err)
	}
	port, _ := atoiPort(portStr)
	return &Node{Proto: ProtoTrojan, Host: host, Port: port, Secret: secret, TLS: TLSMode{Enabled: true, Insecure: true}}
}

func startProxy(t *testing.T, trojanAddr, secret string) (*Proxy, Config) {
	t.Helper()
	// Grab a free port for the local listener.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := portOf(l.Addr().String())
	l.Close()

	cfg := Config{
		Listen:   "127.0.0.1",
		Port:     port,
		Username: "aurora",
		Password: "s3cret-local",
	}
	p, err := Start(cfg, log.New(os.Stderr, "test: ", 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := p.SetNode(trojanNode(t, trojanAddr, secret)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	return p, cfg
}

// socksConnect performs a full SOCKS5 CONNECT and returns the open connection.
func socksConnect(t *testing.T, addr, user, pass, target string) (net.Conn, error) {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return nil, err
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	// greeting: version 5, two methods (no-auth, user/pass)
	if _, err := c.Write([]byte{0x05, 0x02, 0x00, 0x02}); err != nil {
		return nil, err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(c, reply); err != nil {
		return nil, err
	}
	if reply[1] != 0x02 {
		c.Close()
		return nil, fmt.Errorf("server chose method %d", reply[1])
	}
	// RFC1929
	req := []byte{0x01, byte(len(user))}
	req = append(req, user...)
	req = append(req, byte(len(pass)))
	req = append(req, pass...)
	if _, err := c.Write(req); err != nil {
		return nil, err
	}
	ar := make([]byte, 2)
	if _, err := io.ReadFull(c, ar); err != nil {
		return nil, err
	}
	if ar[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("auth rejected (status %d)", ar[1])
	}
	host, portStr, _ := net.SplitHostPort(target)
	p, _ := atoiPort(portStr)
	conn := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}
	conn = append(conn, host...)
	conn = append(conn, byte(p>>8), byte(p))
	if _, err := c.Write(conn); err != nil {
		return nil, err
	}
	rep := make([]byte, 10)
	if _, err := io.ReadFull(c, rep); err != nil {
		return nil, err
	}
	if rep[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("connect rejected (code %d)", rep[1])
	}
	return c, nil
}

func TestSocksRoundTrip(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	trojan := newFakeTrojan(t, secret)
	p, cfg := startProxy(t, trojan.ln.Addr().String(), secret)

	c, err := socksConnect(t, p.Addr(), cfg.Username, cfg.Password, "example.com:443")
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer c.Close()
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(c, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "ping" {
		t.Fatalf("echo = %q", buf)
	}
	time.Sleep(50 * time.Millisecond)
	if trojan.target != "example.com:443" {
		t.Fatalf("trojan target = %q", trojan.target)
	}
	if st := p.Stats(); st.Total == 0 || st.Denied != 0 {
		t.Fatalf("stats = %+v", st)
	}
}

func TestSocksRejectsWrongPassword(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	trojan := newFakeTrojan(t, secret)
	p, cfg := startProxy(t, trojan.ln.Addr().String(), secret)
	if _, err := socksConnect(t, p.Addr(), cfg.Username, "wrong", "example.com:443"); err == nil {
		t.Fatal("wrong password was accepted")
	}
	time.Sleep(80 * time.Millisecond)
	if st := p.Stats(); st.Denied == 0 {
		t.Fatalf("denial not counted: %+v", st)
	}
}

func TestHTTPProxyAuth(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	trojan := newFakeTrojan(t, secret)
	p, cfg := startProxy(t, trojan.ln.Addr().String(), secret)

	// No credentials: 407 and the tunnel never opens.
	c, err := net.Dial("tcp", p.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprintf(c, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
	br := bufio.NewReader(c)
	line, _ := br.ReadString('\n')
	if !strings.Contains(line, "407") {
		t.Fatalf("expected 407, got %q", line)
	}

	// With credentials: 200 and the stream is tunneled.
	c2, err := net.Dial("tcp", p.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	c2.SetDeadline(time.Now().Add(5 * time.Second))
	cred := base64.StdEncoding.EncodeToString([]byte(cfg.Username + ":" + cfg.Password))
	fmt.Fprintf(c2, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: Basic %s\r\n\r\n", cred)
	br2 := bufio.NewReader(c2)
	line2, _ := br2.ReadString('\n')
	if !strings.Contains(line2, "200") {
		t.Fatalf("expected 200, got %q", line2)
	}
	for {
		l, err := br2.ReadString('\n')
		if err != nil || strings.TrimSpace(l) == "" {
			break
		}
	}
	if _, err := c2.Write([]byte("pong")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(br2, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "pong" {
		t.Fatalf("echo = %q", buf)
	}
}

func TestEnvCarriesCredentials(t *testing.T) {
	cfg := Config{Listen: "127.0.0.1", Port: 3128, Username: "aurora", Password: "p@ss word"}
	env := cfg.Env()
	want := "http://aurora:p%40ss%20word@127.0.0.1:3128"
	if env["HTTP_PROXY"] != want || env["http_proxy"] != want {
		t.Fatalf("HTTP_PROXY = %q, want %q", env["HTTP_PROXY"], want)
	}
	if !strings.HasPrefix(env["ALL_PROXY"], "socks5h://aurora:") {
		t.Fatalf("ALL_PROXY = %q", env["ALL_PROXY"])
	}
	if !strings.Contains(env["NO_PROXY"], "127.0.0.1") {
		t.Fatalf("NO_PROXY = %q", env["NO_PROXY"])
	}
}

func TestStartRefusesOpenListener(t *testing.T) {
	if _, err := Start(Config{Listen: "127.0.0.1", Port: 3128}, log.New(io.Discard, "", 0)); err == nil {
		t.Fatal("a proxy without credentials was accepted")
	}
}
