//go:build windows

package p2p

import (
	"net/netip"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// localAddrs reads the adapters directly: only addresses in the preferred
// state, with temporary (random-suffix) IPv6 addresses marked.
func localAddrs() []Local {
	var size uint32 = 16 << 10
	var buf []byte
	for i := 0; i < 3; i++ {
		buf = make([]byte, size)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_DNS_SERVER,
			0, (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			break
		}
		if err != windows.ERROR_BUFFER_OVERFLOW {
			return fallbackAddrs()
		}
		buf = nil
	}
	if buf == nil {
		return fallbackAddrs()
	}
	var out []Local
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); a != nil; a = a.Next {
		if a.OperStatus != windows.IfOperStatusUp || a.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK {
			continue
		}
		name := windows.UTF16PtrToString(a.FriendlyName)
		for u := a.FirstUnicastAddress; u != nil; u = u.Next {
			if u.DadState != windows.IpDadStatePreferred {
				continue
			}
			sa, err := u.Address.Sockaddr.Sockaddr()
			if err != nil {
				continue
			}
			var ip netip.Addr
			switch s := sa.(type) {
			case *syscall.SockaddrInet4:
				ip = netip.AddrFrom4(s.Addr)
			case *syscall.SockaddrInet6:
				ip = netip.AddrFrom16(s.Addr)
			default:
				continue
			}
			out = append(out, Local{IP: ip, Prefix: netip.PrefixFrom(ip, int(u.OnLinkPrefixLength)), Iface: name, Stable: u.SuffixOrigin != windows.IpSuffixOriginRandom})
		}
	}
	return out
}
