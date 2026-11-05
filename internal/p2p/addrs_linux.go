//go:build linux

package p2p

import (
	"encoding/hex"
	"net/netip"
	"os"
	"strconv"
	"strings"
)

const (
	ifaTemporary  = 0x01
	ifaDadFailed  = 0x08
	ifaDeprecated = 0x20
	ifaTentative  = 0x40
)

// localAddrs: IPv4 from the interfaces, IPv6 from /proc/net/if_inet6, which
// carries the temporary/deprecated flags net.Interfaces drops.
func localAddrs() []Local {
	var out []Local
	for _, l := range fallbackAddrs() {
		if l.IP.Is4() {
			out = append(out, l)
		}
	}
	b, err := os.ReadFile("/proc/net/if_inet6")
	if err != nil {
		return fallbackAddrs()
	}
	up := map[string]bool{}
	for _, l := range fallbackAddrs() {
		up[l.Iface] = true
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 6 || len(f[0]) != 32 || f[3] != "00" || !up[f[5]] {
			continue
		}
		raw, err := hex.DecodeString(f[0])
		if err != nil {
			continue
		}
		flags, _ := strconv.ParseUint(f[4], 16, 32)
		if flags&(ifaDeprecated|ifaTentative|ifaDadFailed) != 0 {
			continue
		}
		ip, _ := netip.AddrFromSlice(raw)
		bits, err := strconv.ParseUint(f[2], 16, 8)
		if err != nil || bits > 128 {
			continue
		}
		out = append(out, Local{IP: ip, Prefix: netip.PrefixFrom(ip, int(bits)), Iface: f[5], Stable: flags&ifaTemporary == 0})
	}
	return out
}
