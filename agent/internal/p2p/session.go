package p2p

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"aurora3/internal/wire"

	"github.com/apernet/quic-go"
)

// PingOp answers at once: a QUIC link's round trip at the application level.
const PingOp = "link.ping"

// QUICSession is one QUIC connection used as a wire.Session. Every operation
// is its own QUIC stream, so a lost packet only holds up the streams whose
// data it carried, never the whole link (yamux over TCP stalls them all).
type QUICSession struct {
	Conn    *quic.Conn
	release func()
	once    sync.Once
	n       atomic.Int64

	mu     sync.Mutex
	lastPk uint64
	lastAt time.Time
}

// NewQUICSession wraps c; release runs once when the link ends.
func NewQUICSession(c *quic.Conn, release func()) *QUICSession {
	s := &QUICSession{Conn: c, release: release, lastAt: time.Now()}
	go func() {
		<-c.Context().Done()
		s.Close()
	}()
	return s
}

func (s *QUICSession) wrap(st *quic.Stream) net.Conn {
	s.n.Add(1)
	return &qstream{Stream: st, s: s}
}

func (s *QUICSession) OpenStream() (net.Conn, error) {
	ctx, cancel := context.WithTimeout(s.Conn.Context(), 20*time.Second)
	defer cancel()
	st, err := s.Conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	return s.wrap(st), nil
}

func (s *QUICSession) AcceptStream() (net.Conn, error) {
	st, err := s.Conn.AcceptStream(context.Background())
	if err != nil {
		return nil, err
	}
	return s.wrap(st), nil
}

// Ping runs PingOp on a new stream.
func (s *QUICSession) PingContext(ctx context.Context) (time.Duration, error) {
	start := time.Now()
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := wire.Call(ctx, s, PingOp, nil, nil); err != nil {
		return 0, err
	}
	return time.Since(start), nil
}

func (s *QUICSession) NumStreams() int            { return int(s.n.Load()) }
func (s *QUICSession) IsClosed() bool             { return s.Conn.Context().Err() != nil }
func (s *QUICSession) CloseChan() <-chan struct{} { return s.Conn.Context().Done() }
func (s *QUICSession) Freeze() bool               { return false }

func (s *QUICSession) Close() error {
	s.once.Do(func() {
		_ = s.Conn.CloseWithError(0, "closed")
		if s.release != nil {
			s.release()
		}
	})
	return nil
}

// Idle: QUIC keep-alives arrive every few seconds on a working path, so the
// packet counter standing still means the path is silent.
func (s *QUICSession) Idle() time.Duration {
	pk := s.Conn.ConnectionStats().PacketsReceived
	s.mu.Lock()
	defer s.mu.Unlock()
	if pk != s.lastPk {
		s.lastPk, s.lastAt = pk, time.Now()
	}
	return time.Since(s.lastAt)
}

func (s *QUICSession) Reason() string {
	err := context.Cause(s.Conn.Context())
	if err == nil {
		return ""
	}
	var idle *quic.IdleTimeoutError
	var app *quic.ApplicationError
	switch {
	case errors.As(err, &idle):
		return "QUIC 空闲超时（路径无响应）"
	case errors.As(err, &app) && app.Remote:
		return "对端关闭了连接"
	case errors.As(err, &app):
		return "close: closed locally"
	}
	return err.Error()
}

// RTT is QUIC's own smoothed estimate.
func (s *QUICSession) RTT() time.Duration { return s.Conn.ConnectionStats().SmoothedRTT }

// qstream is one QUIC stream as a net.Conn. Close ends both directions (the
// protocol marks the end of data with frames, never with a half-close).
type qstream struct {
	*quic.Stream
	s    *QUICSession
	once sync.Once
}

func (q *qstream) LocalAddr() net.Addr  { return q.s.Conn.LocalAddr() }
func (q *qstream) RemoteAddr() net.Addr { return q.s.Conn.RemoteAddr() }

func (q *qstream) Close() error {
	q.once.Do(func() {
		q.s.n.Add(-1)
		q.Stream.CancelRead(0)
		_ = q.Stream.Close()
	})
	return nil
}

// Bulk lowers a QUIC stream's send priority so transfers yield to
// interactive operations on the same link (a no-op on other streams).
func Bulk(c net.Conn) {
	if q, ok := c.(*qstream); ok {
		q.Stream.SetPriority(6, true)
	}
}

// DialQUIC opens a forward QUIC connection from a fresh UDP socket; the
// returned func closes the socket once the link ends.
func DialQUIC(ctx context.Context, addr string, tlsConf *tls.Config) (*quic.Conn, func(), error) {
	ua, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, nil, err
	}
	uc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, nil, err
	}
	tr := &quic.Transport{Conn: uc}
	c, err := tr.Dial(ctx, ua, ClientTLS(tlsConf), QUICConfig())
	if err != nil {
		_ = tr.Close()
		_ = uc.Close()
		return nil, nil, err
	}
	return c, func() { _ = tr.Close(); _ = uc.Close() }, nil
}

// Hello runs the client side of the Hello exchange on the first stream of a
// fresh QUIC connection and returns the session on success. release runs
// when the link ends (also on failure).
func Hello(ctx context.Context, c *quic.Conn, h wire.Hello, release func()) (wire.HelloReply, *QUICSession, error) {
	fail := func(err error) (wire.HelloReply, *QUICSession, error) {
		_ = c.CloseWithError(0, "")
		if release != nil {
			release()
		}
		return wire.HelloReply{}, nil, err
	}
	st, err := c.OpenStreamSync(ctx)
	if err != nil {
		return fail(err)
	}
	detach := bindHelloContext(ctx, st)
	defer detach()
	if err := wire.WriteJSON(st, h); err != nil {
		return fail(err)
	}
	var r wire.HelloReply
	if err := wire.ReadJSON(st, &r); err != nil {
		return fail(err)
	}
	st.CancelRead(0)
	_ = st.Close()
	if !r.OK {
		_, _, err := fail(errors.New(r.Error))
		return r, nil, err
	}
	detach()
	if err := ctx.Err(); err != nil {
		return fail(err)
	}
	return r, NewQUICSession(c, release), nil
}

// bindHelloContext interrupts stream reads AND writes on cancellation. Wait for
// an already-running callback before returning, so it cannot touch a handed-off
// session. The stream itself is closed after Hello, so no deadline reset is needed.
func bindHelloContext(ctx context.Context, st *quic.Stream) func() {
	deadline := time.Now().Add(15 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	_ = st.SetDeadline(deadline)
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		st.CancelRead(0)
		st.CancelWrite(0)
		close(done)
	})
	var once sync.Once
	return func() {
		once.Do(func() {
			if !stop() {
				<-done
			}
		})
	}
}

// AcceptHello reads the Hello on the first stream of an accepted QUIC
// connection; answer is called with it and its reply is sent back.
func AcceptHello(ctx context.Context, c *quic.Conn, answer func(wire.Hello) wire.HelloReply) (wire.HelloReply, error) {
	sctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	st, err := c.AcceptStream(sctx)
	if err != nil {
		return wire.HelloReply{}, err
	}
	defer func() { st.CancelRead(0); _ = st.Close() }()
	detach := bindHelloContext(sctx, st)
	defer detach()
	var h wire.Hello
	if err := wire.ReadJSON(st, &h); err != nil {
		return wire.HelloReply{}, err
	}
	r := answer(h)
	if err := wire.WriteJSON(st, r); err != nil {
		return r, err
	}
	return r, nil
}
