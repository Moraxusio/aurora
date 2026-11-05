//go:build linux

package entry

import (
	"net"

	"golang.org/x/sys/unix"
)

// tuneTCP (v2 tcptune_linux.go): a direct link carries terminals next to bulk
// transfers.
//   - TCP_NOTSENT_LOWAT keeps little unsent data in the kernel, so a
//     keystroke echo is not queued behind megabytes of a download.
//   - TCP_THIN_LINEAR_TIMEOUTS retransmits a thin (interactive) flow at a
//     fixed interval instead of backing off exponentially.
func tuneTCP(c net.Conn) {
	tc, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tc.SetNoDelay(true)
	raw, err := tc.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) {
		_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_NOTSENT_LOWAT, 128<<10)
		_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_THIN_LINEAR_TIMEOUTS, 1)
	})
}
