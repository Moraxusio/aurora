//go:build linux

package netfwd

import (
	"context"
	"net"
	"os"
	"testing"
)

// A /proc/net/tcp sample: one listener on 127.0.0.1:8080 (inode 111), one
// established connection (state 01) that must be skipped.
const tcpSample = `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 111 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000     0        0 222 1 0000000000000000 20 4 30 10 -1
`

func TestParseListen(t *testing.T) {
	got := parseListen(tcpSample, false)
	if len(got) != 1 {
		t.Fatalf("want 1 listener, got %v", got)
	}
	if lp := got["111"]; lp.Port != 8080 || lp.Addr != "127.0.0.1" {
		t.Fatalf("listener %+v", lp)
	}
}

func TestHexAddrV6(t *testing.T) {
	// ::1 as /proc/net/tcp6 writes it
	if a := hexAddr("00000000000000000000000001000000", true); a != "::1" {
		t.Fatalf("::1 read as %q", a)
	}
	if a := hexAddr("zz", false); a != "" {
		t.Fatalf("bad hex read as %q", a)
	}
}

// net.ports finds a listener this test opens, with this process as owner
// when Self is another PID; with Self = this PID it is left out.
func TestNetPortsFindsListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	find := func(self int) *openPort {
		res, err := (&Env{Self: self}).netPorts(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range res.(map[string]any)["ports"].([]openPort) {
			if p.Port == port {
				return &p
			}
		}
		return nil
	}
	p := find(1) // pid 1 is never this test
	if p == nil {
		t.Fatalf("port %d not listed", port)
	}
	if p.Pid != os.Getpid() || p.Addr != "127.0.0.1" {
		t.Fatalf("listed as %+v, want pid %d", *p, os.Getpid())
	}
	if find(os.Getpid()) != nil {
		t.Fatal("the agent's own listener must be left out")
	}
}

// One port can have several listeners (a wildcard and a loopback, IPv4 and
// IPv6). The listing keeps one, always the same: the most reachable address,
// whatever order they were read in.
func TestDedupePortsIsStable(t *testing.T) {
	in := []openPort{
		{Port: 53, Addr: "127.0.0.54", Pid: 7},
		{Port: 22, Addr: "::", Pid: 9},
		{Port: 53, Addr: "127.0.0.53", Pid: 7},
		{Port: 22, Addr: "0.0.0.0", Pid: 9},
		{Port: 80, Addr: "127.0.0.1"},
		{Port: 80, Addr: "10.0.0.5", Pid: 3},
	}
	want := func(got []openPort) string {
		s := ""
		for _, p := range got {
			s += p.Addr + " "
		}
		return s
	}
	first := want(dedupePorts(in))
	if first != "0.0.0.0 127.0.0.53 10.0.0.5 " && first != ":: 127.0.0.53 10.0.0.5 " {
		t.Fatalf("got %q", first)
	}
	// the wildcard chosen for 22 is the same one every time, in every order
	for i := 0; i < 50; i++ {
		shuffled := append([]openPort(nil), in...)
		for j := range shuffled {
			k := (j*7 + i*3) % len(shuffled)
			shuffled[j], shuffled[k] = shuffled[k], shuffled[j]
		}
		if got := want(dedupePorts(shuffled)); got != first {
			t.Fatalf("order changed the result: %q vs %q", got, first)
		}
	}
	// ports come out sorted
	got := dedupePorts(in)
	if got[0].Port != 22 || got[1].Port != 53 || got[2].Port != 80 {
		t.Fatalf("not sorted: %+v", got)
	}
}
