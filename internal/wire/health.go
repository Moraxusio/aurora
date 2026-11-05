package wire

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// TrackedConn records when bytes last arrived and the first error the
// connection hit, so a link can be judged alive by what it carries and its
// end can be explained in the log.
type TrackedConn struct {
	net.Conn
	lastRead atomic.Int64 // monotonic nanos since clockBase
	once     sync.Once
	err      atomic.Value // string
	opened   time.Time
	frozen   atomic.Bool
	gone     chan struct{}
	goneOnce sync.Once
}

var clockBase = time.Now()

func mono() int64 { return int64(time.Since(clockBase)) }

// Track wraps c. Wrap the raw TCP connection (below TLS) so every byte counts.
func Track(c net.Conn) *TrackedConn {
	t := &TrackedConn{Conn: c, opened: time.Now(), gone: make(chan struct{})}
	t.lastRead.Store(mono())
	return t
}

func (t *TrackedConn) Read(p []byte) (int, error) {
	n, err := t.Conn.Read(p)
	if t.frozen.Load() {
		<-t.gone // a frozen path delivers nothing, until it is closed
		return 0, net.ErrClosed
	}
	if n > 0 {
		t.lastRead.Store(mono())
	}
	if err != nil {
		t.fail("read", err)
	}
	return n, err
}

func (t *TrackedConn) Write(p []byte) (int, error) {
	if t.frozen.Load() {
		<-t.gone
		return 0, net.ErrClosed
	}
	n, err := t.Conn.Write(p)
	if err != nil {
		t.fail("write", err)
	}
	return n, err
}

// Freeze makes the connection behave like a network path that died without
// a word: nothing more is delivered either way, no error is raised. Used by
// tests and the client's fault-injection hook.
func (t *TrackedConn) Freeze() { t.frozen.Store(true) }

func (t *TrackedConn) Close() error {
	t.goneOnce.Do(func() { close(t.gone) })
	t.fail("close", errors.New("closed locally"))
	return t.Conn.Close()
}

func (t *TrackedConn) fail(op string, err error) {
	t.once.Do(func() {
		msg := op + ": " + err.Error()
		switch {
		case errors.Is(err, io.EOF):
			msg = "对端关闭了连接"
		case errors.Is(err, os.ErrDeadlineExceeded):
			msg = op + " 超时"
		}
		t.err.Store(msg)
	})
}

// Idle is the time since bytes last arrived.
func (t *TrackedConn) Idle() time.Duration {
	return time.Duration(mono() - t.lastRead.Load())
}

// Age is how long the connection has existed.
func (t *TrackedConn) Age() time.Duration { return time.Since(t.opened) }

// Reason is the first error, or "" while the connection is healthy.
func (t *TrackedConn) Reason() string {
	if v, ok := t.err.Load().(string); ok {
		return v
	}
	return ""
}

// Health is what one probe concluded about a link.
type Health int

const (
	// Alive: the ping was answered (or data kept arriving while it queued).
	Alive Health = iota
	// Stalled: nothing arrived for a while. The path may come back (a TCP
	// flow in retransmission backoff after Wi-Fi lost a burst, a QUIC path
	// recovering), so the link is not closed: new operations go elsewhere and
	// a replacement is dialed while the transfers on it may still finish.
	Stalled
	// Dead: closed, or silent for DeadAfter.
	Dead
)

// Probe timings. A ping must be answered, or at least some bytes must keep
// arriving (a pong may queue behind a big transfer on yamux, but then the
// transfer itself keeps arriving). An idle link gets IdleWait.
// Only active probes (including lock waiters) own registry entries. Removing
// an entry when its last user leaves avoids retaining disconnected sessions,
// without a cleanup goroutine per session or racing a waiter onto a new lock.
var probeLocks = struct {
	sync.Mutex
	active map[Session]*probeLock
}{active: make(map[Session]*probeLock)}

type probeLock struct {
	sync.Mutex
	users int
}

func lockProbe(s Session) func() {
	probeLocks.Lock()
	lock := probeLocks.active[s]
	if lock == nil {
		lock = &probeLock{}
		probeLocks.active[s] = lock
	}
	lock.users++
	probeLocks.Unlock()
	lock.Lock()
	return func() {
		lock.Unlock()
		probeLocks.Lock()
		lock.users--
		if lock.users == 0 {
			delete(probeLocks.active, s)
		}
		probeLocks.Unlock()
	}
}

var (
	IdleAfter = 15 * time.Second
	IdleWait  = 3 * time.Second
	BusyWait  = 4 * time.Second
	// DeadAfter: silence after which a link is given up for good.
	DeadAfter = 25 * time.Second
)

// Probe pings the session once and judges it.
func Probe(s Session) (rtt time.Duration, h Health) {
	if s == nil || s.IsClosed() {
		return 0, Dead
	}
	unlock := lockProbe(s)
	defer unlock()
	if s.IsClosed() {
		return 0, Dead
	}
	wait := BusyWait
	if s.Idle() > IdleAfter {
		wait = IdleWait
	}
	type res struct {
		rtt time.Duration
		err error
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := make(chan res, 1)
	go func() {
		r, err := s.PingContext(ctx)
		select {
		case ch <- res{r, err}:
		case <-ctx.Done():
		}
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		select {
		case r := <-ch:
			if r.err != nil {
				if s.IsClosed() {
					return 0, Dead
				}
				return 0, Stalled
			}
			return r.rtt, Alive
		case <-timer.C:
			idle := s.Idle()
			if idle < wait {
				// Data is flowing; the pong is just queued. Look again later.
				timer.Reset(wait - idle + 100*time.Millisecond)
				continue
			}
			if idle >= DeadAfter || s.IsClosed() {
				return 0, Dead
			}
			return 0, Stalled
		}
	}
}

// KeepChecking probes s every interval until it closes, and closes it only
// when it is dead: a stalled link may recover, and the peer that dials (the
// client) replaces it meanwhile. onDead (optional) is told why.
func KeepChecking(s Session, interval time.Duration, onDead func(idle time.Duration)) {
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-s.CloseChan():
			return
		case <-tick.C:
		}
		if _, h := Probe(s); h == Dead {
			if s.IsClosed() {
				return
			}
			if onDead != nil {
				onDead(s.Idle())
			}
			s.Close()
			return
		}
	}
}
