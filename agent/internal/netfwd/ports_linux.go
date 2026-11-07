//go:build linux

package netfwd

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type openPort struct {
	Port    int    `json:"port"`
	Addr    string `json:"addr"`
	Pid     int    `json:"pid,omitempty"`
	Process string `json:"process,omitempty"`
	Command string `json:"command,omitempty"`
}

func (e *Env) netPorts(ctx context.Context, _ json.RawMessage) (any, error) {
	inodes := map[string]openPort{}
	for _, f := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		for ino, lp := range parseListen(readFile(f), strings.HasSuffix(f, "6")) {
			if _, ok := inodes[ino]; !ok {
				inodes[ino] = lp
			}
		}
	}
	// which process owns each socket (bounded: a busy server has many)
	deadline := time.Now().Add(2 * time.Second)
	procs, _ := os.ReadDir("/proc")
	self := e.Self
	if self == 0 {
		self = os.Getpid()
	}
	for _, p := range procs {
		if time.Now().After(deadline) || ctx.Err() != nil {
			break
		}
		pid, err := strconv.Atoi(p.Name())
		if err != nil {
			continue
		}
		dir := filepath.Join("/proc", p.Name())
		fds, err := os.ReadDir(filepath.Join(dir, "fd"))
		if err != nil {
			continue
		}
		for _, fd := range fds {
			l, err := os.Readlink(filepath.Join(dir, "fd", fd.Name()))
			if err != nil || !strings.HasPrefix(l, "socket:[") {
				continue
			}
			ino := strings.TrimSuffix(strings.TrimPrefix(l, "socket:["), "]")
			if lp, ok := inodes[ino]; ok && lp.Pid == 0 {
				lp.Pid = pid
				lp.Process = strings.TrimSpace(readFile(filepath.Join(dir, "comm")))
				cmd := strings.ReplaceAll(strings.TrimRight(readFile(filepath.Join(dir, "cmdline")), "\x00"), "\x00", " ")
				if len(cmd) > 160 {
					cmd = cmd[:160]
				}
				lp.Command = cmd
				inodes[ino] = lp
			}
		}
	}
	all := make([]openPort, 0, len(inodes))
	for _, lp := range inodes {
		if lp.Pid != self {
			all = append(all, lp) // the agent's own listeners are left out
		}
	}
	return map[string]any{"ports": dedupePorts(all)}, nil
}

// dedupePorts keeps one listener per port, sorted by port. A port can have
// several (0.0.0.0 and ::, or 127.0.0.53 and 127.0.0.54); which one is shown
// must not depend on map order. The address reachable from furthest away wins
// (a wildcard, then a real interface, then a loopback), so the list never
// understates who can connect; a listener whose owner is known comes next, and
// the address text settles a tie.
func dedupePorts(all []openPort) []openPort {
	best := map[int]openPort{}
	for _, lp := range all {
		if old, ok := best[lp.Port]; !ok || betterPort(lp, old) {
			best[lp.Port] = lp
		}
	}
	out := make([]openPort, 0, len(best))
	for _, lp := range best {
		out = append(out, lp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out
}

func exposure(addr string) int {
	if addr == "0.0.0.0" || addr == "::" {
		return 2
	}
	if ip := net.ParseIP(addr); ip != nil && ip.IsLoopback() {
		return 0
	}
	return 1
}

func betterPort(a, b openPort) bool {
	if ea, eb := exposure(a.Addr), exposure(b.Addr); ea != eb {
		return ea > eb
	}
	if (a.Pid != 0) != (b.Pid != 0) {
		return a.Pid != 0
	}
	return a.Addr < b.Addr
}

// parseListen reads /proc/net/tcp{,6}: listening sockets by inode.
func parseListen(text string, v6 bool) map[string]openPort {
	out := map[string]openPort{}
	sc := bufio.NewScanner(strings.NewReader(text))
	first := true
	for sc.Scan() {
		if first {
			first = false
			continue
		}
		f := strings.Fields(sc.Text())
		if len(f) < 10 || f[3] != "0A" {
			continue
		}
		host, port, ok := strings.Cut(f[1], ":")
		if !ok {
			continue
		}
		p, err := strconv.ParseInt(port, 16, 32)
		if err != nil {
			continue
		}
		out[f[9]] = openPort{Port: int(p), Addr: hexAddr(host, v6)}
	}
	return out
}

// hexAddr: /proc stores each 32-bit word of the address in little-endian order.
func hexAddr(h string, v6 bool) string {
	b, err := hex.DecodeString(h)
	if err != nil || (!v6 && len(b) != 4) || (v6 && len(b) != 16) {
		return ""
	}
	for i := 0; i+4 <= len(b); i += 4 {
		b[i], b[i+1], b[i+2], b[i+3] = b[i+3], b[i+2], b[i+1], b[i]
	}
	return net.IP(b).String()
}

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}
