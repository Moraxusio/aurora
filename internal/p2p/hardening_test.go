package p2p

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestEndpointCloseIdempotent(t *testing.T) {
	e, err := Open(0, NewNonce(), KindClient)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	called := make(chan struct{}, 1)
	e.Start(ctx, func(*net.UDPAddr) { called <- struct{}{} })
	e.Close()
	e.Close()
	select {
	case <-called:
		t.Fatal("callback after close")
	case <-time.After(100 * time.Millisecond):
	}
}
