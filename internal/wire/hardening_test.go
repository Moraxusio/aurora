package wire

import (
	"context"
	"net"
	"runtime"
	"sync"
	"testing"
	"time"
)

type stalledSession struct {
	close chan struct{}
	mu    sync.Mutex
	pings int
}

func (s *stalledSession) OpenStream() (net.Conn, error)   { return nil, context.Canceled }
func (s *stalledSession) AcceptStream() (net.Conn, error) { return nil, context.Canceled }
func (s *stalledSession) PingContext(context.Context) (time.Duration, error) {
	s.mu.Lock()
	s.pings++
	s.mu.Unlock()
	select {}
}
func (s *stalledSession) NumStreams() int            { return 0 }
func (s *stalledSession) IsClosed() bool             { return false }
func (s *stalledSession) CloseChan() <-chan struct{} { return s.close }
func (s *stalledSession) Close() error               { return nil }
func (s *stalledSession) Idle() time.Duration        { return time.Hour }
func (s *stalledSession) Reason() string             { return "" }
func (s *stalledSession) Freeze() bool               { return true }
func TestRepeatedProbeSingleInflight(t *testing.T) {
	old := IdleAfter
	IdleAfter = -1
	defer func() { IdleAfter = old }()
	s := &stalledSession{close: make(chan struct{})}
	before := runtime.NumGoroutine()
	done := make(chan struct{})
	go func() { Probe(s); close(done) }()
	time.Sleep(20 * time.Millisecond)
	Probe(s)
	<-done
	s.mu.Lock()
	n := s.pings
	s.mu.Unlock()
	if n != 2 {
		t.Fatalf("pings=%d", n)
	}
	if runtime.NumGoroutine() > before+4 {
		t.Fatal("goroutines grew")
	}
}
func TestAcceptReleaseContextIdempotent(t *testing.T) {
	l := NewAcceptLimiter(1, 1, nil)
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	rel := l.Acquire(a)
	if rel == nil {
		t.Fatal("acquire")
	}
	ctx := WithAcceptRelease(context.Background(), rel)
	ReleaseAccept(ctx)
	AcceptReleaseFrom(ctx)()
	if l.Acquire(a) == nil {
		t.Fatal("slot not released")
	}
}
