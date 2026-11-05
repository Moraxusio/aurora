// Package netproxy gives every Aurora session an outbound proxy without
// touching the rest of the machine.
//
// The upstream is a Trojan server on the VPS; the local end is a SOCKS5/HTTP
// listener bound to loopback that requires a username and password. On a shared
// server that password is what keeps other local users off your tunnel: the
// port alone is not a secret, credentials in a 0600 file are.
package netproxy

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"aurora3/internal/wire"
)

// Endpoint is one Trojan entry point. The IPv6 and IPv4 listeners of a VPS are
// separate users there, so each carries its own secret.
type Endpoint struct {
	Addr   string `json:"addr"`
	Secret string `json:"secret"`
}

// Upstream describes the Trojan servers the sessions' traffic leaves through.
type Upstream struct {
	// Endpoints are tried in order, so a broken IPv6 route falls back to IPv4.
	Endpoints []Endpoint `json:"endpoints"`
	SNI       string     `json:"sni,omitempty"`
	Pin       string     `json:"pin,omitempty"`      // hex SHA-256 of the server certificate
	Insecure  bool       `json:"insecure,omitempty"` // last resort, no pin
	Timeout   int        `json:"timeout_seconds,omitempty"`
	// Hy2 is the preferred transport when set; Endpoints are the fallback.
	Hy2 *Hy2 `json:"hy2,omitempty"`
}

// Valid reports whether the upstream has enough to attempt a connection.
func (u Upstream) Valid() bool {
	if len(u.Endpoints) == 0 || (u.Pin == "" && !u.Insecure) {
		return false
	}
	for _, e := range u.Endpoints {
		if e.Addr == "" || len(e.Secret) < 16 {
			return false
		}
	}
	return true
}

// Addrs lists the endpoint addresses for logs and status output.
func (u Upstream) Addrs() []string {
	out := make([]string, 0, len(u.Endpoints)+1)
	if u.Hy2.Valid() {
		out = append(out, "hy2://"+u.Hy2.Addr)
	}
	for _, e := range u.Endpoints {
		out = append(out, e.Addr)
	}
	return out
}

func (u Upstream) timeout() time.Duration {
	if u.Timeout <= 0 {
		return 8 * time.Second
	}
	return time.Duration(u.Timeout) * time.Second
}

func (u Upstream) tlsConfig() *tls.Config {
	cfg := &tls.Config{ServerName: u.SNI, MinVersion: tls.VersionTLS12}
	switch {
	case u.Pin != "":
		want := strings.ToLower(strings.TrimSpace(u.Pin))
		// VerifyConnection replaces chain validation with a certificate pin, so
		// a self-signed cert is fine but an impostor is not.
		cfg.InsecureSkipVerify = true
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return wire.ErrPinMismatch
			}
			got := wire.CertPin(cs.PeerCertificates[0].Raw)
			if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
				return wire.ErrPinMismatch
			}
			return nil
		}
	case u.Insecure:
		cfg.InsecureSkipVerify = true
	}
	return cfg
}

// crlfBytes is the two-byte line terminator the protocol uses.
var crlfBytes = []byte{0x0d, 0x0a}

// trojanPassword is hex(SHA-224(secret)), sent before every request.
func trojanPassword(secret string) string {
	sum := sha256.Sum224([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// DialContext opens a tunnel to target ("host:port") through the first upstream
// server that answers.
func (u Upstream) DialContext(ctx context.Context, target string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return nil, fmt.Errorf("目标地址无效：%w", err)
	}
	port, ok := atoiPort(portStr)
	if !ok {
		return nil, errors.New("目标端口无效")
	}
	var last error
	for _, ep := range u.Endpoints {
		addr := strings.TrimSpace(ep.Addr)
		if addr == "" {
			continue
		}
		header, err := trojanHeader(ep.Secret, host, port)
		if err != nil {
			return nil, err
		}
		conn, err := u.dialOne(ctx, addr, header)
		if err != nil {
			last = fmt.Errorf("%s: %w", addr, err)
			continue
		}
		return conn, nil
	}
	if last == nil {
		last = errors.New("没有可用的上游服务器")
	}
	return nil, last
}

func (u Upstream) dialOne(ctx context.Context, server string, header []byte) (net.Conn, error) {
	d := &net.Dialer{Timeout: u.timeout()}
	raw, err := d.DialContext(ctx, "tcp", server)
	if err != nil {
		return nil, err
	}
	c := tls.Client(raw, u.tlsConfig())
	hctx, cancel := context.WithTimeout(ctx, u.timeout())
	defer cancel()
	if err := c.HandshakeContext(hctx); err != nil {
		raw.Close()
		return nil, err
	}
	if _, err := c.Write(header); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

// trojanHeader builds the request prelude: password, CRLF, then the CONNECT
// command and destination, then CRLF.
func trojanHeader(secret, host string, port int) ([]byte, error) {
	out := make([]byte, 0, 128)
	out = append(out, trojanPassword(secret)...)
	out = append(out, crlfBytes[:]...)
	out = append(out, 0x01) // CONNECT
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			out = append(out, 0x01)
			out = append(out, v4...)
		} else {
			out = append(out, 0x04)
			out = append(out, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return nil, errors.New("目标域名过长")
		}
		out = append(out, 0x03, byte(len(host)))
		out = append(out, host...)
	}
	out = append(out, byte(port>>8), byte(port))
	out = append(out, crlfBytes[:]...)
	return out, nil
}

func atoiPort(s string) (int, bool) {
	if s == "" || len(s) > 5 {
		return 0, false
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	if n < 1 || n > 65535 {
		return 0, false
	}
	return n, true
}

// relay copies bytes in both directions until either side closes.
func relay(a, b net.Conn) {
	var once sync.Once
	closeBoth := func() { once.Do(func() { a.Close(); b.Close() }) }
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		_, _ = copyBuffered(dst, src)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	closeBoth()
	<-done
}
