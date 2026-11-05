package wire

import (
	"os"
	"sync"
)

// RotatingFile is an append-only log that never grows past Max bytes: when
// full it becomes <path>.1 (replacing the previous one) and a new file starts.
// A process that runs for weeks keeps at most 2*Max of log on disk.
type RotatingFile struct {
	Path string
	Max  int64
	Mode os.FileMode

	mu   sync.Mutex
	f    *os.File
	size int64
}

func (r *RotatingFile) open() error {
	f, err := os.OpenFile(r.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, r.Mode)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	r.f, r.size = f, st.Size()
	return nil
}

func (r *RotatingFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		if err := r.open(); err != nil {
			return 0, err
		}
	}
	if r.size+int64(len(p)) > r.Max && r.size > 0 {
		r.f.Close()
		r.f = nil
		_ = os.Rename(r.Path, r.Path+".1")
		if err := r.open(); err != nil {
			return 0, err
		}
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

func (r *RotatingFile) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Close()
	r.f = nil
	return err
}
