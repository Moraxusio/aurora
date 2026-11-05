package wire

import (
	"log"
	"net"
	"net/netip"
	"sync"
)

// AcceptLimiter bounds unauthenticated handshakes.
type AcceptLimiter struct {
	mu                       sync.Mutex
	global, maxGlobal, maxIP int
	perIP                    map[string]int
	log                      *log.Logger
}

func NewAcceptLimiter(maxGlobal, maxIP int, l *log.Logger) *AcceptLimiter {
	return &AcceptLimiter{maxGlobal: maxGlobal, maxIP: maxIP, perIP: map[string]int{}, log: l}
}
func (l *AcceptLimiter) key(c net.Conn) string {
	return l.keyAddr(c.RemoteAddr())
}
func (l *AcceptLimiter) keyAddr(addr net.Addr) string {
	a, ok := addr.(*net.TCPAddr)
	if !ok {
		return addr.String()
	}
	ip, _ := netip.AddrFromSlice(a.IP)
	if ip.IsLoopback() {
		return "loopback"
	}
	if ip.Is6() {
		return netip.PrefixFrom(ip, 64).Masked().String()
	}
	return ip.String()
}
func (l *AcceptLimiter) Acquire(c net.Conn) func() {
	return l.acquireKey(l.key(c))
}

// AcquireAddr reserves a pre-auth slot for a connection represented by its address.
func (l *AcceptLimiter) AcquireAddr(addr net.Addr) func() {
	return l.acquireKey(l.keyAddr(addr))
}
func (l *AcceptLimiter) acquireKey(k string) func() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.global >= l.maxGlobal || (k != "loopback" && l.perIP[k] >= l.maxIP) {
		if l.log != nil {
			l.log.Printf("pre-auth limit exceeded for %s", k)
		}
		return nil
	}
	l.global++
	if k == "loopback" {
		return func() { l.mu.Lock(); l.global--; l.mu.Unlock() }
	}
	l.perIP[k]++
	return func() {
		l.mu.Lock()
		l.global--
		l.perIP[k]--
		if l.perIP[k] == 0 {
			delete(l.perIP, k)
		}
		l.mu.Unlock()
	}
}
