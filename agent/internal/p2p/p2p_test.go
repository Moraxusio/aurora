package p2p

import (
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"strconv"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func TestMeetOverQUIC(t *testing.T) {
	old := candidateAllowed
	candidateAllowed = func(ap netip.AddrPort, local []netip.Prefix) bool { return ap.IsValid() && ap.Port() != 0 }
	defer func() { candidateAllowed = old }()
	cert, pin, err := wire.LoadOrCreateCert(t.TempDir(), "agent")
	if err != nil {
		t.Fatal(err)
	}
	nonce := NewNonce()
	ag, err := Open(0, nonce, KindAgent)
	if err != nil {
		t.Fatal(err)
	}
	cl, err := Open(0, nonce, KindClient)
	if err != nil {
		t.Fatal(err)
	}
	ln, err := ag.Tr.Listen(ServerTLS(cert), QUICConfig())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go func() {
		c, err := ln.Accept(ctx)
		if err != nil {
			return
		}
		r, err := AcceptHello(ctx, c, func(h wire.Hello) wire.HelloReply {
			return wire.HelloReply{OK: h.Token == "tok", Error: "认证失败", Version: wire.Version}
		})
		if err != nil || !r.OK {
			_ = c.CloseWithError(0, "")
			return
		}
		s := NewQUICSession(c, ag.Hold())
		for {
			st, err := s.AcceptStream()
			if err != nil {
				return
			}
			go func() {
				defer st.Close()
				var req wire.Request
				if wire.ReadJSON(st, &req) == nil {
					_ = wire.WriteJSON(st, wire.OKResponse(map[string]string{"op": req.Op}))
				}
			}()
		}
	}()
	// A wrong-nonce endpoint must not be taken for the peer.
	stranger, _ := Open(0, NewNonce(), KindAgent)
	defer stranger.Close()
	stranger.AddTargets([]string{"127.0.0.1:" + itoa(cl.Port())})
	stranger.Start(ctx, nil)

	ag.AddTargets([]string{"127.0.0.1:" + itoa(cl.Port())})
	cl.AddTargets([]string{"127.0.0.1:" + itoa(ag.Port())})
	peer := make(chan *net.UDPAddr, 4)
	ag.Start(ctx, nil)
	cl.Start(ctx, func(a *net.UDPAddr) { peer <- a })
	var from *net.UDPAddr
	select {
	case from = <-peer:
	case <-ctx.Done():
		t.Fatal("no punch packet")
	}
	if from.Port != ag.Port() {
		t.Fatalf("peer %v is not the agent (port %d)", from, ag.Port())
	}
	// A wrong pin is refused.
	if _, err := cl.Tr.Dial(ctx, from, ClientTLS(wire.PinnedTLS(wire.NewToken())), QUICConfig()); err == nil {
		t.Fatal("wrong pin accepted")
	}
	qc, err := cl.Tr.Dial(ctx, from, ClientTLS(wire.PinnedTLS(pin)), QUICConfig())
	if err != nil {
		t.Fatal(err)
	}
	_, s, err := Hello(ctx, qc, wire.Hello{Token: "tok"}, cl.Hold())
	if err != nil {
		t.Fatal(err)
	}
	cl.Done() // held by the link: stays open
	for i := 0; i < 20; i++ {
		var out map[string]string
		if err := wire.Call(ctx, s, "x", nil, &out); err != nil || out["op"] != "x" {
			t.Fatalf("call %d: %v %v", i, out, err)
		}
	}
	if s.NumStreams() != 0 {
		t.Fatalf("streams leaked: %d", s.NumStreams())
	}
	if rtt, err := s.PingContext(context.Background()); err != nil || rtt < 0 {
		t.Fatalf("ping %v %v", rtt, err)
	}
	if s.Idle() > time.Second {
		t.Fatalf("idle %s on a live link", s.Idle())
	}
	s.Close()
	ag.Done()
	time.Sleep(200 * time.Millisecond)
	if _, err := cl.UDP.WriteTo([]byte{0}, from); err == nil {
		t.Fatal("client endpoint still open after its last link closed")
	}
	if s.Reason() == "" {
		t.Fatal("no reason for a closed link")
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func TestParseSTUN(t *testing.T) {
	b := make([]byte, 32)
	binary.BigEndian.PutUint16(b[0:], 0x0101)
	binary.BigEndian.PutUint16(b[2:], 12)
	binary.BigEndian.PutUint32(b[4:], stunMagic)
	copy(b[8:20], "abcdefghijkl")
	binary.BigEndian.PutUint16(b[20:], 0x0020)
	binary.BigEndian.PutUint16(b[22:], 8)
	b[25] = 0x01
	binary.BigEndian.PutUint16(b[26:], 40000^(stunMagic>>16))
	ip := []byte{203, 0, 113, 7}
	var m [4]byte
	binary.BigEndian.PutUint32(m[:], stunMagic)
	for i := range ip {
		b[28+i] = ip[i] ^ m[i]
	}
	tx, a := parseSTUN(b)
	if a == nil || a.String() != "203.0.113.7:40000" || string(tx[:]) != "abcdefghijkl" {
		t.Fatalf("got %v", a)
	}
}

func TestAddrs(t *testing.T) {
	for _, l := range Addrs() {
		t.Logf("%s %s stable=%v", l.IP, l.Iface, l.Stable)
		if !usable(l.IP) {
			t.Fatalf("unusable %s listed", l.IP)
		}
	}
}
