package netproxy

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// dialTransport opens the byte stream a VLESS or VMess header is written to:
// plain TCP, TCP inside TLS, or a WebSocket (with or without TLS) as the
// node's provider configured it (D-87). The returned connection is already
// past its handshakes.
func dialTransport(ctx context.Context, n Node, timeout time.Duration) (net.Conn, error) {
	d := &net.Dialer{Timeout: timeout}
	if n.Transport == "ws" {
		return dialWS(ctx, n, d, timeout)
	}
	raw, err := d.DialContext(ctx, "tcp", n.Addr())
	if err != nil {
		return nil, err
	}
	if !n.TLS.Enabled {
		return raw, nil
	}
	c := tls.Client(raw, n.tlsConfig())
	hctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := c.HandshakeContext(hctx); err != nil {
		raw.Close()
		return nil, err
	}
	return c, nil
}

// dialWS runs the WebSocket handshake over a connection this package dials
// itself, so the certificate rules of D-88 are the ones that apply and the
// address is the node's, whatever Host header the CDN in front expects.
func dialWS(ctx context.Context, n Node, d *net.Dialer, timeout time.Duration) (net.Conn, error) {
	scheme := "ws"
	if n.TLS.Enabled {
		scheme = "wss"
	}
	path := n.WSPath
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	host := n.WSHost
	if host == "" {
		host = n.TLS.SNI
	}
	if host == "" {
		host = n.Host
	}
	u := url.URL{Scheme: scheme, Host: n.Addr()}
	if i := strings.IndexByte(path, '?'); i >= 0 {
		u.Path, u.RawQuery = path[:i], path[i+1:]
	} else {
		u.Path = path
	}
	hc := &http.Client{Transport: &http.Transport{
		// The address is the node's; the name in the URL only picks the Host
		// header, so every connection goes where the node says.
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return d.DialContext(ctx, network, n.Addr())
		},
		TLSClientConfig:       n.tlsConfig(),
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
		DisableCompression:    true,
		ForceAttemptHTTP2:     false,
		// A nil map turns HTTP/2 off, which a WebSocket upgrade needs.
		TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{},
	}}
	// coder/websocket binds the connection's life to ctx, so ctx must outlive
	// the dial; the caller's deadline only bounds the handshake.
	hctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ws, _, err := websocket.Dial(hctx, u.String(), &websocket.DialOptions{
		HTTPClient: hc,
		Host:       host,
		HTTPHeader: http.Header{"User-Agent": []string{"Mozilla/5.0"}},
	})
	if err != nil {
		return nil, fmt.Errorf("WebSocket 连接失败：%w", err)
	}
	return &wsConn{Conn: websocket.NetConn(context.Background(), ws, websocket.MessageBinary), ws: ws}, nil
}

// wsConn closes without waiting for the peer. The library's Close sends the
// WebSocket close frame and then waits for the server's, which some servers
// take a second to send or never send; a tunnel that has ended must free its
// slot at once, or the proxy's connection limit fills up with closed tunnels.
type wsConn struct {
	net.Conn
	ws   *websocket.Conn
	once sync.Once
}

func (c *wsConn) Close() error {
	c.once.Do(func() {
		go func() { _ = c.ws.CloseNow() }()
	})
	return nil
}
