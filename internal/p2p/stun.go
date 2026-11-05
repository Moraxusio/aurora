package p2p

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"net"
	"sync"
	"time"
)

// STUNServers answer binding requests from mainland networks.
var STUNServers = []string{"stun.miwifi.com:3478", "stun.chat.bilibili.com:3478"}

const stunMagic = 0x2112A442

var stunLookupIP = func(ctx context.Context, network, host string) ([]net.IP, error) {
	r := net.Resolver{}
	return r.LookupIP(ctx, network, host)
}

// STUN asks the servers which public address this socket appears as (the
// mapping a NAT gives it) and returns the distinct answers. The reader must be
// running. IPv4 only: IPv6 addresses are public as they are.
func (e *Endpoint) STUN(ctx context.Context, servers []string) []string {
	var mu sync.Mutex
	seen := map[string]bool{}
	var out []string
	var wg sync.WaitGroup
	for _, s := range servers {
		wg.Add(1)
		go func(s string) {
			defer wg.Done()
			ips, err := stunLookupIP(ctx, "ip4", hostOf(s))
			if err != nil || len(ips) == 0 {
				return
			}
			port := 3478
			if _, p, err := net.SplitHostPort(s); err == nil {
				if n, err := net.LookupPort("udp", p); err == nil {
					port = n
				}
			}
			for _, ip := range ips {
				attempt, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
				a := e.stunOnce(attempt, &net.UDPAddr{IP: ip, Port: port})
				cancel()
				if a == nil {
					continue
				}
				mu.Lock()
				if k := a.String(); !seen[k] {
					seen[k] = true
					out = append(out, k)
				}
				mu.Unlock()
				break
			}
		}(s)
	}
	wg.Wait()
	return out
}

func hostOf(hp string) string {
	if h, _, err := net.SplitHostPort(hp); err == nil {
		return h
	}
	return hp
}

func (e *Endpoint) stunOnce(ctx context.Context, srv *net.UDPAddr) *net.UDPAddr {
	var tx [12]byte
	_, _ = rand.Read(tx[:])
	req := make([]byte, 20)
	binary.BigEndian.PutUint16(req[0:], 0x0001)
	binary.BigEndian.PutUint32(req[4:], stunMagic)
	copy(req[8:], tx[:])
	ch := make(chan *net.UDPAddr, 1)
	e.mu.Lock()
	e.stun[tx] = ch
	e.mu.Unlock()
	defer func() { e.mu.Lock(); delete(e.stun, tx); e.mu.Unlock() }()
	for i := 0; i < 3; i++ {
		_, _ = e.Tr.WriteTo(req, srv)
		select {
		case a := <-ch:
			return a
		case <-ctx.Done():
			return nil
		case <-time.After(250 * time.Millisecond):
		}
	}
	return nil
}

func (e *Endpoint) stunResponse(b []byte) {
	tx, a := parseSTUN(b)
	if a == nil {
		return
	}
	e.mu.Lock()
	ch := e.stun[tx]
	e.mu.Unlock()
	if ch != nil {
		select {
		case ch <- a:
		default:
		}
	}
}

// parseSTUN reads the mapped address of a Binding Success response.
func parseSTUN(b []byte) (tx [12]byte, addr *net.UDPAddr) {
	if len(b) < 20 || binary.BigEndian.Uint16(b[0:]) != 0x0101 || binary.BigEndian.Uint32(b[4:]) != stunMagic {
		return tx, nil
	}
	copy(tx[:], b[8:20])
	n := int(binary.BigEndian.Uint16(b[2:]))
	attrs := b[20:]
	if n < len(attrs) {
		attrs = attrs[:n]
	}
	var plain *net.UDPAddr
	for len(attrs) >= 4 {
		t, l := binary.BigEndian.Uint16(attrs[0:]), int(binary.BigEndian.Uint16(attrs[2:]))
		if 4+l > len(attrs) {
			break
		}
		v := attrs[4 : 4+l]
		if (t == 0x0020 || t == 0x0001) && l >= 8 && v[1] == 0x01 {
			port := binary.BigEndian.Uint16(v[2:])
			ip := net.IP(append([]byte{}, v[4:8]...))
			if t == 0x0020 {
				port ^= stunMagic >> 16
				var m [4]byte
				binary.BigEndian.PutUint32(m[:], stunMagic)
				for i := range ip {
					ip[i] ^= m[i]
				}
				return tx, &net.UDPAddr{IP: ip, Port: int(port)}
			}
			plain = &net.UDPAddr{IP: ip, Port: int(port)}
		}
		attrs = attrs[4+(l+3)&^3:]
	}
	return tx, plain
}
