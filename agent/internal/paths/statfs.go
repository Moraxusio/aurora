//go:build linux

package paths

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Bounded disk statistics, copied from v2 files.go. A hung network mount must not
// pin an OS thread per request, so each mount point has at most one statfs in flight.
var mountInfoReader = func() ([]string, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.SplitN(line, " - ", 2)
		if len(f) == 0 {
			continue
		}
		fields := strings.Fields(f[0])
		if len(fields) >= 5 {
			out = append(out, strings.ReplaceAll(fields[4], "\\040", " "))
		}
	}
	return out, nil
}

var (
	statfsBusy  sync.Map // mount point -> *statfsCall
	statfsSlots = make(chan struct{}, 4)
	mountMu     sync.Mutex
	mountAt     time.Time
	mounts      []string
	statfsProbe = func(p string, st *syscall.Statfs_t) bool {
		fi, err := os.Stat(p)
		return err == nil && fi.IsDir() && syscall.Statfs(p, st) == nil
	}
)

func statfsMount(p string) string {
	mountMu.Lock()
	defer mountMu.Unlock()
	if time.Since(mountAt) > 10*time.Second || mounts == nil {
		mounts = mounts[:0]
		if ms, err := mountInfoReader(); err == nil {
			mounts = append(mounts, ms...)
		}
		mountAt = time.Now()
	}
	best := "/"
	for _, m := range mounts {
		if (p == m || strings.HasPrefix(p, strings.TrimSuffix(m, "/")+"/")) && len(m) > len(best) {
			best = m
		}
	}
	return best
}

// statfsCall is one statfs in flight; callers that arrive meanwhile wait for
// its answer instead of reporting the drive as unavailable.
type statfsCall struct {
	done chan struct{}
	st   syscall.Statfs_t
	ok   bool
}

// StatfsBounded returns the filesystem statistics of p, or false when it cannot be
// read within 2 s.
func StatfsBounded(p string) (syscall.Statfs_t, bool) {
	key := statfsMount(filepath.Clean(p))
	c := &statfsCall{done: make(chan struct{})}
	if v, busy := statfsBusy.LoadOrStore(key, c); busy {
		c = v.(*statfsCall)
	} else {
		select {
		case statfsSlots <- struct{}{}:
		default:
			statfsBusy.Delete(key)
			return syscall.Statfs_t{}, false
		}
		go func() {
			defer statfsBusy.Delete(key)
			defer func() { <-statfsSlots }()
			c.ok = statfsProbe(p, &c.st)
			close(c.done)
		}()
	}
	select {
	case <-c.done:
		return c.st, c.ok
	case <-time.After(2 * time.Second):
		return syscall.Statfs_t{}, false
	}
}
