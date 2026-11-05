package wire

import (
	"net"
	"sync"
	"testing"
	"time"

	"github.com/hashicorp/yamux"
)

// gate is a pipe that can be frozen: bytes stop flowing in both directions,
// like a network path that silently died.
type gate struct {
	net.Conn
	mu     sync.Mutex
	frozen bool
	cond   *sync.Cond
}

func newGate(c net.Conn) *gate { g := &gate{Conn: c}; g.cond = sync.NewCond(&g.mu); return g }
func (g *gate) wait() {
	g.mu.Lock()
	for g.frozen {
		g.cond.Wait()
	}
	g.mu.Unlock()
}
func (g *gate) Read(p []byte) (int, error)  { n, err := g.Conn.Read(p); g.wait(); return n, err }
func (g *gate) Write(p []byte) (int, error) { g.wait(); return g.Conn.Write(p) }
func (g *gate) freeze()                     { g.mu.Lock(); g.frozen = true; g.mu.Unlock() }
func (g *gate) thaw()                       { g.mu.Lock(); g.frozen = false; g.cond.Broadcast(); g.mu.Unlock() }

func pair(t *testing.T) (*Mux, *TrackedConn, *gate, *gate) {
	a, b := net.Pipe()
	ga, gb := newGate(a), newGate(b)
	tc := Track(ga)
	cs, err := yamux.Client(tc, MuxConfig())
	if err != nil {
		t.Fatal(err)
	}
	ss, err := yamux.Server(gb, MuxConfig())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ga.thaw(); gb.thaw(); cs.Close(); ss.Close() })
	return NewMux(cs, tc), tc, ga, gb
}

func TestProbeRegistryReleasesSessions(t *testing.T) {
	for i := 0; i < 20; i++ {
		s, _, _, _ := pair(t)
		if _, h := Probe(s); h != Alive {
			t.Fatal(h)
		}
		s.Close()
	}
	probeLocks.Lock()
	retained := len(probeLocks.active)
	probeLocks.Unlock()
	if retained != 0 {
		t.Fatalf("retained %d sessions after probes ended", retained)
	}
}

func TestProbeLockWaitersShareEntryAndReleaseIt(t *testing.T) {
	s, _, _, _ := pair(t)
	unlock := lockProbe(s)
	acquired, done := make(chan struct{}), make(chan struct{})
	go func() { release := lockProbe(s); close(acquired); release(); close(done) }()
	deadline := time.Now().Add(time.Second)
	for {
		probeLocks.Lock()
		users := probeLocks.active[s].users
		probeLocks.Unlock()
		if users == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("waiter not registered")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-acquired:
		t.Fatal("same-session probes overlapped")
	default:
	}
	unlock()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("waiter stuck")
	}
	probeLocks.Lock()
	_, retained := probeLocks.active[s]
	probeLocks.Unlock()
	if retained {
		t.Fatal("idle registry entry retained session")
	}
}

func TestProbeHealthyLink(t *testing.T) {
	s, _, _, _ := pair(t)
	if _, h := Probe(s); h != Alive {
		t.Fatal("healthy link not reported alive")
	}
}

func TestProbeNoticesASilentlyDeadIdleLink(t *testing.T) {
	old := IdleAfter
	IdleAfter = -1 // treat the link as idle
	defer func() { IdleAfter = old }()
	s, _, ga, gb := pair(t)
	ga.freeze()
	gb.freeze()
	start := time.Now()
	if _, h := Probe(s); h != Stalled {
		t.Fatalf("silent link reported %v, want stalled", h)
	}
	if d := time.Since(start); d > IdleWait+time.Second {
		t.Fatalf("took %s", d)
	}
	// Long silence: dead.
	old2 := DeadAfter
	DeadAfter = 0
	defer func() { DeadAfter = old2 }()
	if _, h := Probe(s); h != Dead {
		t.Fatalf("long-silent link reported %v, want dead", h)
	}
}

// A stalled link that comes back is alive again.
func TestProbeStallRecovers(t *testing.T) {
	old := IdleAfter
	IdleAfter = -1
	defer func() { IdleAfter = old }()
	s, _, ga, gb := pair(t)
	ga.freeze()
	gb.freeze()
	if _, h := Probe(s); h != Stalled {
		t.Fatalf("got %v", h)
	}
	ga.thaw()
	gb.thaw()
	if _, h := Probe(s); h != Alive {
		t.Fatalf("recovered link reported %v", h)
	}
}

func TestTrackedConnExplainsTheEnd(t *testing.T) {
	a, b := net.Pipe()
	tc := Track(a)
	b.Close()
	buf := make([]byte, 1)
	_, _ = tc.Read(buf)
	if tc.Reason() == "" {
		t.Fatal("no reason recorded")
	}
}
