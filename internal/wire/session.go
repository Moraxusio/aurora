package wire

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"strings"
	"time"

	"github.com/hashicorp/yamux"
)

// MuxConfig is shared by every Aurora peer.
func MuxConfig() *yamux.Config {
	c := yamux.DefaultConfig()
	c.AcceptBacklog = 512
	c.EnableKeepAlive = true
	c.KeepAliveInterval = 15 * time.Second
	c.ConnectionWriteTimeout = 30 * time.Second
	c.StreamOpenTimeout = 20 * time.Second
	c.StreamCloseTimeout = 2 * time.Minute
	c.MaxStreamWindowSize = 4 * 1024 * 1024
	c.LogOutput = io.Discard
	return c
}

// MajorCompatible reports whether two protocol versions share a major number.
func MajorCompatible(a, b string) bool {
	ma, _, _ := strings.Cut(a, ".")
	mb, _, _ := strings.Cut(b, ".")
	return ma != "" && ma == mb
}

// Opener opens one stream per operation (any Session).
type Opener interface {
	OpenStream() (net.Conn, error)
}

// Session is one link between a client and an agent. Two kinds exist: yamux
// over a TLS/TCP connection (Mux) and a QUIC connection whose own streams
// carry the operations (p2p.QUICSession). Every operation opens a stream.
type Session interface {
	OpenStream() (net.Conn, error)
	AcceptStream() (net.Conn, error)
	// Ping measures one round trip at the link level and stops when ctx ends.
	PingContext(ctx context.Context) (time.Duration, error)
	NumStreams() int
	IsClosed() bool
	CloseChan() <-chan struct{}
	Close() error
	// Idle is the time since anything last arrived from the peer.
	Idle() time.Duration
	// Reason explains how the link ended ("" while it is up).
	Reason() string
	// Freeze simulates a path that silently died (test hook); false when the
	// transport does not support it.
	Freeze() bool
}

// Mux is a yamux session over a tracked connection.
type Mux struct {
	*yamux.Session
	Conn *TrackedConn // below TLS; nil in tests
}

func NewMux(s *yamux.Session, tc *TrackedConn) *Mux { return &Mux{Session: s, Conn: tc} }

func (m *Mux) OpenStream() (net.Conn, error) {
	st, err := m.Session.OpenStream()
	if err != nil {
		return nil, err
	}
	return st, nil
}

func (m *Mux) AcceptStream() (net.Conn, error) {
	st, err := m.Session.AcceptStream()
	if err != nil {
		return nil, err
	}
	return st, nil
}

func (m *Mux) PingContext(ctx context.Context) (time.Duration, error) {
	start := time.Now()
	ch := make(chan error, 1)
	go func() { _, err := m.Session.Ping(); ch <- err }()
	select {
	case err := <-ch:
		if err != nil {
			return 0, err
		}
		return time.Since(start), nil
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

func (m *Mux) Idle() time.Duration {
	if m.Conn == nil {
		return 0
	}
	return m.Conn.Idle()
}

func (m *Mux) Reason() string {
	if m.Conn == nil {
		return ""
	}
	return m.Conn.Reason()
}

func (m *Mux) Freeze() bool {
	if m.Conn == nil {
		return false
	}
	m.Conn.Freeze()
	return true
}

// Call runs a unary operation on its own stream.
func Call(ctx context.Context, s Opener, op string, args any, out any) error {
	st, err := s.OpenStream()
	if err != nil {
		return Errf(CodeUnavailable, "连接不可用：%v", err)
	}
	defer st.Close()
	stop := context.AfterFunc(ctx, func() { st.Close() })
	defer stop()
	if dl, ok := ctx.Deadline(); ok {
		_ = st.SetDeadline(dl)
	}
	if err := WriteRequest(st, op, args); err != nil {
		return err
	}
	var resp Response
	if err := ReadJSON(st, &resp); err != nil {
		if ctx.Err() != nil {
			return Errf(CodeUnavailable, "请求超时")
		}
		return Errf(CodeUnavailable, "连接中断：%v", err)
	}
	if err := resp.Err(); err != nil {
		return err
	}
	if out != nil && len(resp.Result) > 0 {
		return json.Unmarshal(resp.Result, out)
	}
	return nil
}

func WriteRequest(w io.Writer, op string, args any) error {
	var raw json.RawMessage
	switch a := args.(type) {
	case nil:
	case json.RawMessage:
		raw = a
	default:
		b, err := json.Marshal(a)
		if err != nil {
			return err
		}
		raw = b
	}
	return WriteJSON(w, Request{Op: op, Args: raw})
}

// HandshakeDeadline bounds the hello exchange on fresh connections.
func HandshakeDeadline(c net.Conn) func() {
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	return func() { _ = c.SetDeadline(time.Time{}) }
}
