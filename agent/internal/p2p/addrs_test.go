package p2p

import (
	"net"
	"net/netip"
	"testing"
)

// Exercise the OS-selected production enumerator, not hand-written prefixes.
func TestLocalPrefixesUseInterfaceMasks(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	expected := map[netip.Addr]netip.Prefix{}
	for _, ifc := range interfaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		as, err := ifc.Addrs()
		if err != nil {
			t.Fatal(err)
		}
		for _, a := range as {
			p, err := netip.ParsePrefix(a.String())
			if err != nil {
				continue
			}
			expected[p.Addr()] = p.Masked()
		}
	}
	prefixes := LocalPrefixes()
	checked := 0
	for _, l := range localAddrs() {
		p, ok := expected[l.IP]
		if !ok || p.Bits() == 0 {
			continue
		}
		if l.Prefix.Masked() != p {
			t.Fatalf("%s mask = %s, interface reports %s", l.IP, l.Prefix, p)
		}
		found := false
		for _, got := range prefixes {
			if got == p {
				found = true
			}
		}
		if !found {
			t.Fatalf("production prefix missing: %s", p)
		}
		if l.IP.IsPrivate() && p.Bits() < l.IP.BitLen()-1 {
			peer := p.Addr().Next()
			if peer == l.IP {
				peer = peer.Next()
			}
			if !AllowedCandidate(netip.AddrPortFrom(peer, 443), prefixes) {
				t.Fatalf("same-subnet private peer denied: %s in %s", peer, p)
			}
		}
		checked++
	}
	if checked == 0 {
		t.Skip("no active non-loopback addresses")
	}
}

func TestAllowedCandidate(t *testing.T) {
	local := []netip.Prefix{netip.MustParsePrefix("192.168.1.0/24"), netip.MustParsePrefix("fd00::/8")}
	cases := []struct {
		a    string
		want bool
	}{{"127.0.0.1:1", false}, {"0.0.0.0:1", false}, {"224.0.0.1:1", false}, {"169.254.1.1:1", false}, {"192.168.1.2:1", true}, {"192.168.2.2:1", false}, {"8.8.8.8:1", true}, {"1.1.1.1:0", false}, {"[fd00::2]:1", true}, {"fe80::1:1", false}}
	for _, tt := range cases {
		t.Run(tt.a, func(t *testing.T) {
			a, _ := netip.ParseAddrPort(tt.a)
			if got := AllowedCandidate(a, local); got != tt.want {
				t.Fatalf("got %v", got)
			}
		})
	}
}
