package update

import (
	"context"
	"errors"
	"sync"
	"time"
)

// Gate counts file-transfer lifetimes rather than all requests: terminals do
// not prevent an upgrade. Once a quiet window is reached, new transfers are
// refused until the upgrade completes or its preparation fails.
type Gate struct {
	mu     sync.Mutex
	active int
	last   time.Time
	sealed bool
}

func (g *Gate) Enter() (func(), error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.sealed {
		return nil, errors.New("agent 正在升级，请稍后再传输")
	}
	g.active++
	g.last = time.Now()
	var once sync.Once
	return func() { once.Do(func() { g.mu.Lock(); g.active--; g.last = time.Now(); g.mu.Unlock() }) }, nil
}
func (g *Gate) Unseal() { g.mu.Lock(); g.sealed = false; g.last = time.Now(); g.mu.Unlock() }
func (g *Gate) Seal(ctx context.Context, quiet time.Duration) error {
	start := time.Now()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		g.mu.Lock()
		last := g.last
		if last.Before(start) {
			last = start
		}
		if g.active == 0 && time.Since(last) >= quiet {
			g.sealed = true
			g.mu.Unlock()
			return nil
		}
		g.mu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}
