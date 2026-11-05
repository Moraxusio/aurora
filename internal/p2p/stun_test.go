package p2p

import (
	"context"
	"encoding/binary"
	"net"
	"strconv"
	"testing"
)

func TestSTUNTriesEveryResolvedIPv4(t *testing.T) {
	e, err := Open(0, NewNonce(), KindClient)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	srv, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	old := stunLookupIP
	defer func() { stunLookupIP = old }()
	stunLookupIP = func(context.Context, string, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("192.0.2.1"), net.ParseIP("127.0.0.1")}, nil
	}
	go func() {
		b := make([]byte, 1500)
		n, a, err := srv.ReadFromUDP(b)
		if err != nil {
			return
		}
		resp := make([]byte, 32)
		binary.BigEndian.PutUint16(resp, 0x0101)
		binary.BigEndian.PutUint16(resp[2:], 12)
		binary.BigEndian.PutUint32(resp[4:], stunMagic)
		copy(resp[8:20], b[8:n])
		binary.BigEndian.PutUint16(resp[20:], 0x0001)
		binary.BigEndian.PutUint16(resp[22:], 8)
		resp[25] = 1
		binary.BigEndian.PutUint16(resp[26:], 40000)
		copy(resp[28:], []byte{127, 0, 0, 1})
		_, _ = srv.WriteToUDP(resp, a)
	}()
	e.StartReader(context.Background())
	got := e.STUN(context.Background(), []string{"fake:" + strconv.Itoa(srv.LocalAddr().(*net.UDPAddr).Port)})
	if len(got) != 1 || got[0] != "127.0.0.1:40000" {
		t.Fatalf("got %v", got)
	}
}
