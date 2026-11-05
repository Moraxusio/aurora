package wire

import (
	"io"
	"log"
	"net"
	"sync"
	"testing"
)

func testConn(ip string) net.Conn {
	a, b := net.Pipe()
	_ = b.Close()
	return &addrConn{Conn: a, addr: &net.TCPAddr{IP: net.ParseIP(ip), Port: 1}}
}

type addrConn struct {
	net.Conn
	addr net.Addr
}

func (c *addrConn) RemoteAddr() net.Addr { return c.addr }
func TestAcceptLimiter(t *testing.T) {
	l := NewAcceptLimiter(3, 2, log.New(io.Discard, "", 0))
	a := testConn("2001:db8:1::1")
	a2 := testConn("2001:db8:1::2")
	b := testConn("2001:db8:2::1")
	r1 := l.Acquire(a)
	r2 := l.Acquire(a2)
	if r1 == nil || r2 == nil {
		t.Fatal("acquire")
	}
	if l.Acquire(testConn("2001:db8:1::3")) != nil {
		t.Fatal("/64 cap")
	}
	r3 := l.Acquire(b)
	if r3 == nil {
		t.Fatal("global")
	}
	if l.Acquire(testConn("2001:db8:3::1")) != nil {
		t.Fatal("global cap")
	}
	r1()
	if l.Acquire(testConn("2001:db8:1::4")) == nil {
		t.Fatal("release")
	}
	r2()
	r3()
}
func TestAcceptLimiterConcurrent(t *testing.T) {
	l := NewAcceptLimiter(8, 8, nil)
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if r := l.Acquire(testConn("192.0.2.1")); r != nil {
				r()
			}
		}()
	}
	wg.Wait()
}
