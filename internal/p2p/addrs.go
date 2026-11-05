package p2p

import (
	"net"
	"net/netip"
	"sort"
	"strconv"
	"strings"
)

// Local is one address of this machine.
type Local struct {
	IP     netip.Addr
	Prefix netip.Prefix // actual interface mask, not a host route
	Iface  string
	Stable bool // IPv6: not a temporary (privacy) address
}

// virtualIface: container, VPN and VM interfaces a remote peer cannot use.
func virtualIface(name string) bool {
	n := strings.ToLower(name)
	for _, p := range []string{"docker", "veth", "cali", "cni", "flannel", "br-", "virbr", "tunl", "vxlan", "kube", "nodelocaldns",
		"tailscale", "wg", "tun", "lxc", "zerotier", "vethernet", "vmware", "virtualbox", "bluetooth", "npcap", "loopback", "isatap", "teredo"} {
		if strings.HasPrefix(n, p) {
			return true
		}
	}
	return false
}

func usable(ip netip.Addr) bool {
	if !ip.IsValid() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}
	if ip.Is6() && !ip.Is4In6() {
		// Unique local (fc00::/7) belongs to VPNs here; 2002::/16 is 6to4.
		b := ip.As16()
		if b[0]&0xfe == 0xfc || (b[0] == 0x20 && b[1] == 0x02) {
			return false
		}
		return true
	}
	ip = ip.Unmap()
	// CGNAT 100.64/10 is Tailscale or a carrier NAT: unreachable from outside.
	if ip.As4()[0] == 100 && ip.As4()[1]&0xc0 == 64 {
		return false
	}
	return true
}

// Addrs lists usable addresses: stable IPv6 first, then IPv4, then temporary
// IPv6. Deprecated and tentative IPv6 addresses are left out.
func Addrs() []Local {
	ls := localAddrs()
	out := ls[:0]
	for _, l := range ls {
		if usable(l.IP) && !virtualIface(l.Iface) {
			l.IP = l.IP.Unmap()
			out = append(out, l)
		}
	}
	rank := func(l Local) int {
		switch {
		case l.IP.Is6() && l.Stable:
			return 0
		case l.IP.Is4():
			return 1
		}
		return 2
	}
	sort.SliceStable(out, func(i, j int) bool { return rank(out[i]) < rank(out[j]) })
	return out
}

// AllowedCandidate accepts only addresses safe to contact as peer candidates.
func AllowedCandidate(ap netip.AddrPort, local []netip.Prefix) bool {
	if !ap.IsValid() || ap.Port() == 0 {
		return false
	}
	a := ap.Addr().Unmap()
	if a.IsLoopback() || a.IsUnspecified() || a.IsMulticast() || a.IsLinkLocalUnicast() {
		return false
	}
	private := a.IsPrivate()
	if a.Is6() {
		b := a.As16()
		private = private || b[0]&0xfe == 0xfc
	}
	if private {
		for _, p := range local {
			if p.Contains(a) {
				return true
			}
		}
		return false
	}
	return true
}

// LocalPrefixes returns interface networks used to authorize private peers.
func LocalPrefixes() []netip.Prefix {
	var out []netip.Prefix
	for _, l := range localAddrs() {
		if l.Prefix.IsValid() && l.Prefix.Bits() > 0 && l.Prefix.Contains(l.IP) {
			out = append(out, l.Prefix.Masked())
		}
	}
	return out
}

func HostPorts(ls []Local, port int, v6only bool) []string {
	var out []string
	seen := map[string]bool{}
	for _, l := range ls {
		if v6only && !l.IP.Is6() {
			continue
		}
		s := net.JoinHostPort(l.IP.String(), strconv.Itoa(port))
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// fallbackAddrs: interface addresses without flags.
func fallbackAddrs() []Local {
	var out []Local
	ifs, _ := net.Interfaces()
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		as, _ := ifc.Addrs()
		for _, a := range as {
			if ipn, ok := a.(*net.IPNet); ok {
				if ip, ok := netip.AddrFromSlice(ipn.IP); ok {
					bits, size := ipn.Mask.Size()
					ip = ip.Unmap()
					if size == 128 && ip.Is4() {
						bits -= 96
					}
					out = append(out, Local{IP: ip, Prefix: netip.PrefixFrom(ip, bits), Iface: ifc.Name, Stable: true})
				}
			}
		}
	}
	return out
}
