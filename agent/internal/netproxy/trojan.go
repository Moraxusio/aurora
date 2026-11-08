// Package netproxy gives every Aurora session an outbound proxy without
// touching the rest of the machine.
//
// The local end is a SOCKS5/HTTP listener bound to loopback that requires a
// username and password. On a shared server that password is what keeps other
// local users off your tunnel: the port alone is not a secret, credentials in
// a 0600 file are. The far end is one Node (node.go): a Trojan, Hysteria2,
// VLESS or VMess server the user picked from a subscription or typed in.
package netproxy

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

// crlfBytes is the two-byte line terminator the protocol uses.
var crlfBytes = []byte{0x0d, 0x0a}

// trojanPassword is hex(SHA-224(secret)), sent before every request.
func trojanPassword(secret string) string {
	sum := sha256.Sum224([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// trojanDialer opens a TLS connection to the node and writes the Trojan
// request: the hashed password, the CONNECT command and the destination.
type trojanDialer struct {
	n       Node
	timeout time.Duration
}

func (d *trojanDialer) Close() {}

func (d *trojanDialer) DialContext(ctx context.Context, target string) (net.Conn, error) {
	host, port, err := splitTarget(target)
	if err != nil {
		return nil, err
	}
	header := trojanHeader(d.n.Secret, host, port)
	raw, err := (&net.Dialer{Timeout: d.timeout}).DialContext(ctx, "tcp", d.n.Addr())
	if err != nil {
		return nil, err
	}
	c := tls.Client(raw, d.n.tlsConfig())
	hctx, cancel := context.WithTimeout(ctx, d.timeout)
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
func trojanHeader(secret, host string, port int) []byte {
	out := make([]byte, 0, 128)
	out = append(out, trojanPassword(secret)...)
	out = append(out, crlfBytes...)
	out = append(out, 0x01) // CONNECT
	out = appendSocksAddr(out, host, port)
	return append(out, crlfBytes...)
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

var errNoNode = errors.New("还没有选择代理节点")

// errTargetRefused means the node reached the far side and it said no.
type errTargetRefused struct{ msg string }

func (e errTargetRefused) Error() string { return fmt.Sprintf("目标拒绝连接：%s", e.msg) }
