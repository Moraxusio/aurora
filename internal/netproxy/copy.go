package netproxy

import (
	"io"
	"sync"
)

var bufPool = sync.Pool{New: func() any { b := make([]byte, 32<<10); return &b }}

// copyBuffered is io.Copy with a pooled buffer, so a busy session does not
// allocate 32 KB per direction per connection.
func copyBuffered(dst io.Writer, src io.Reader) (int64, error) {
	bp := bufPool.Get().(*[]byte)
	defer bufPool.Put(bp)
	return io.CopyBuffer(dst, src, *bp)
}
