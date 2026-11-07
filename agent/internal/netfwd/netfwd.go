// Package netfwd serves the "net" service (D-45): net.ports lists the TCP
// ports something listens on here, and net.dial connects to one of them and
// carries raw bytes both ways over the stream. The client listens on its own
// loopback and opens one net.dial stream per local connection (port
// forwarding). Ported from v2 internal/agent/netfwd.go.
package netfwd

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"aurora3/internal/wire"
)

// Env is what the net service needs from the agent. Forwarded connections are
// not audited one by one (a web page opens dozens); starting the agent and
// switching the service are.
type Env struct {
	// Self is the agent's own PID; its listeners are left out of net.ports.
	// Zero means os.Getpid().
	Self int
}

type dialArgs struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

// checkDial validates a net.dial target: a port, and a host name or address
// without spaces, slashes or NUL (v2's rule).
func checkDial(a *dialArgs) error {
	if a.Host == "" {
		a.Host = "127.0.0.1"
	}
	if a.Port < 1 || a.Port > 65535 || len(a.Host) > 253 || strings.ContainsAny(a.Host, " /\\\x00") {
		return wire.Errf(wire.CodeBadRequest, "地址无效")
	}
	return nil
}

func (e *Env) netDial(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var a dialArgs
	if err := decode(raw, &a); err != nil {
		return err
	}
	if err := checkDial(&a); err != nil {
		return err
	}
	addr := net.JoinHostPort(a.Host, strconv.Itoa(a.Port))
	c, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return wire.Errf(wire.CodeUnavailable, "服务器上连不上 %s：%v", addr, err)
	}
	defer c.Close()
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"ok": true})); err != nil {
		return nil
	}
	var once sync.Once
	done := make(chan struct{})
	end := func() { once.Do(func() { close(done) }) }
	go func() {
		_, _ = io.Copy(c, st)
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.CloseWrite() // the client finished sending; its answer may still come
		} else {
			end()
		}
	}()
	go func() { _, _ = io.Copy(st, c); end() }()
	select {
	case <-done:
	case <-ctx.Done():
	}
	return nil
}

func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}
