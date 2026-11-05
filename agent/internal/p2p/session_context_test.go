package p2p

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"aurora3/internal/wire"
	"github.com/apernet/quic-go"
)

func helloPair(t *testing.T) (*quic.Conn, *quic.Conn) {
	t.Helper()
	cert, pin, err := wire.LoadOrCreateCert(t.TempDir(), "hello")
	if err != nil {
		t.Fatal(err)
	}
	ln, err := quic.ListenAddr("127.0.0.1:0", ServerTLS(cert), QUICConfig())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	accepted := make(chan *quic.Conn, 1)
	go func() { c, _ := ln.Accept(ctx); accepted <- c }()
	c, release, err := DialQUIC(ctx, ln.Addr().String(), wire.PinnedTLS(pin))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.CloseWithError(0, ""); release() })
	s := <-accepted
	if s == nil {
		t.Fatal("server accept failed")
	}
	t.Cleanup(func() { s.CloseWithError(0, "") })
	return c, s
}

func TestHelloContextCancelsBlockedRead(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "deadline"}[deadline], func(t *testing.T) {
			c, s := helloPair(t)
			read := make(chan struct{})
			go func() {
				st, err := s.AcceptStream(context.Background())
				if err != nil {
					return
				}
				var h wire.Hello
				if wire.ReadJSON(st, &h) == nil {
					close(read)
				}
			}()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if deadline {
				ctx, cancel = context.WithTimeout(ctx, 100*time.Millisecond)
				defer cancel()
			}
			var released atomic.Int32
			done := make(chan error, 1)
			go func() { _, _, err := Hello(ctx, c, wire.Hello{}, func() { released.Add(1) }); done <- err }()
			select {
			case <-read:
			case <-time.After(time.Second):
				t.Fatal("hello not read")
			}
			if !deadline {
				cancel()
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("canceled hello succeeded")
				}
			case <-time.After(time.Second):
				t.Fatal("hello ignored context")
			}
			if released.Load() != 1 {
				t.Fatalf("release count %d", released.Load())
			}
		})
	}
}

func TestAcceptHelloContextCancelsBlockedRead(t *testing.T) {
	c, s := helloPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := AcceptHello(ctx, s, func(wire.Hello) wire.HelloReply { return wire.HelloReply{OK: true} })
		done <- err
	}()
	st, err := c.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// Force a stream onto the wire without completing its frame.
	if _, err := st.Write([]byte{0}); err != nil {
		t.Fatal(err)
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled accept succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("accept ignored context")
	}
}

func TestHelloSuccessDetachesContext(t *testing.T) {
	c, s := helloPair(t)
	ready := make(chan error, 1)
	go func() {
		_, err := AcceptHello(context.Background(), s, func(wire.Hello) wire.HelloReply { return wire.HelloReply{OK: true} })
		ready <- err
	}()
	ctx, cancel := context.WithCancel(context.Background())
	_, session, err := Hello(ctx, c, wire.Hello{}, nil)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	defer session.Close()
	if err := <-ready; err != nil {
		t.Fatal(err)
	}
	cancel()
	// Cancellation belongs only to the handshake, not the returned connection.
	stream, err := session.OpenStream()
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if _, err := stream.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if session.IsClosed() {
		t.Fatal("handshake cancellation closed session")
	}
}
