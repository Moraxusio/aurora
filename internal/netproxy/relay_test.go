package netproxy

import (
	"net"
	"testing"
	"time"
)

func TestRelayStopsWhenOneSideCloses(t *testing.T) {
	a, b := net.Pipe()
	done := make(chan struct{})
	go func() { relay(a, b); close(done) }()
	_ = a.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("relay did not stop")
	}
	if _, err := b.Write([]byte("x")); err == nil {
		t.Fatal("peer remained open")
	}
}
