package netproxy

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// parseUUID reads the 16 bytes of a UUID written with or without dashes.
func parseUUID(s string) ([16]byte, error) {
	var out [16]byte
	h := strings.ReplaceAll(strings.TrimSpace(s), "-", "")
	if len(h) != 32 {
		return out, errors.New("UUID 长度不对")
	}
	b, err := hex.DecodeString(h)
	if err != nil {
		return out, err
	}
	copy(out[:], b)
	return out, nil
}

// vlessDialer speaks VLESS without a flow: a version byte, the user's UUID, an
// empty addon block, the command, and the destination. The server answers with
// a version byte and an empty addon block before the payload (XTLS Vision, the
// only flow in common use, is refused by Node.Check).
type vlessDialer struct {
	n       Node
	timeout time.Duration
}

func (d *vlessDialer) Close() {}

// VLESS and VMess write the destination as port first, then a type byte that
// is 1 for IPv4, 2 for a domain and 3 for IPv6: not the SOCKS5 numbering.
func appendVAddr(out []byte, host string, port int) []byte {
	out = append(out, byte(port>>8), byte(port))
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			out = append(out, 0x01)
			return append(out, v4...)
		}
		out = append(out, 0x03)
		return append(out, ip.To16()...)
	}
	out = append(out, 0x02, byte(len(host)))
	return append(out, host...)
}

func vlessHeader(id [16]byte, host string, port int) []byte {
	out := make([]byte, 0, 64)
	out = append(out, 0x00) // version
	out = append(out, id[:]...)
	out = append(out, 0x00) // no addons
	out = append(out, 0x01) // TCP
	return appendVAddr(out, host, port)
}

func (d *vlessDialer) DialContext(ctx context.Context, target string) (net.Conn, error) {
	host, port, err := splitTarget(target)
	if err != nil {
		return nil, err
	}
	id, err := parseUUID(d.n.Secret)
	if err != nil {
		return nil, err
	}
	c, err := dialTransport(ctx, d.n, d.timeout)
	if err != nil {
		return nil, err
	}
	// The request goes out with the first bytes the caller writes would be
	// ideal, but a SOCKS or HTTP CONNECT client waits for our reply before it
	// sends anything, so the header goes now and the server's own reply is
	// swallowed on the first read.
	if _, err := c.Write(vlessHeader(id, host, port)); err != nil {
		c.Close()
		return nil, err
	}
	return &vlessConn{Conn: c}, nil
}

// vlessConn drops the two-byte response header (version, addon length and the
// addons themselves) before the first payload byte.
type vlessConn struct {
	net.Conn
	done bool
}

func (c *vlessConn) Read(p []byte) (int, error) {
	if !c.done {
		var h [2]byte
		if _, err := io.ReadFull(c.Conn, h[:]); err != nil {
			return 0, err
		}
		if h[0] != 0x00 {
			return 0, fmt.Errorf("VLESS 响应版本无效：%d", h[0])
		}
		if h[1] > 0 {
			if _, err := io.CopyN(io.Discard, c.Conn, int64(h[1])); err != nil {
				return 0, err
			}
		}
		c.done = true
	}
	return c.Conn.Read(p)
}
