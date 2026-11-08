package netproxy

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	hyclient "github.com/apernet/hysteria/core/v2/client"
	hyerrors "github.com/apernet/hysteria/core/v2/errors"
	"golang.org/x/crypto/blake2b"
)

// hy2Dialer carries every tunnel as a stream of one long-lived QUIC connection
// to the node, over UDP. Hysteria2 is the protocol to choose when the path to
// the node loses packets: its congestion control keeps the link full where a
// TCP connection tops out.
type hy2Dialer struct {
	n   Node
	log *log.Logger

	mu     sync.Mutex
	client hyclient.Client
}

func newHy2Dialer(n Node, logf func(string, ...any)) *hy2Dialer {
	d := &hy2Dialer{n: n}
	if logf != nil {
		d.log = log.New(logWriter(logf), "", 0)
	}
	return d
}

type logWriter func(string, ...any)

func (w logWriter) Write(p []byte) (int, error) { w("%s", string(p)); return len(p), nil }

func (d *hy2Dialer) get() (hyclient.Client, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.client != nil {
		return d.client, nil
	}
	c, err := hyclient.NewReconnectableClient(d.config, nil, true)
	if err != nil {
		return nil, err
	}
	d.client = c
	return c, nil
}

func (d *hy2Dialer) config() (*hyclient.Config, error) {
	addr, err := net.ResolveUDPAddr("udp", d.n.Addr())
	if err != nil {
		return nil, err
	}
	sni := d.n.TLS.SNI
	if sni == "" {
		sni = d.n.Host
	}
	skip, verify := d.n.hyVerify()
	cfg := &hyclient.Config{
		ServerAddr: addr,
		Auth:       d.n.Secret,
		TLSConfig: hyclient.TLSConfig{
			ServerName:            sni,
			InsecureSkipVerify:    skip,
			VerifyPeerCertificate: verify,
		},
		BandwidthConfig: hyclient.BandwidthConfig{
			MaxTx: uint64(d.n.UpMbps) * 125000,
			MaxRx: uint64(d.n.DownMbps) * 125000,
		},
	}
	if d.n.Obfs == "salamander" {
		cfg.ConnFactory = salamanderFactory{psk: []byte(d.n.ObfsPassword)}
	}
	return cfg, nil
}

// DialContext opens a stream to target. The library call has no context, so
// the wait is bounded here and a stream that arrives late is closed.
func (d *hy2Dialer) DialContext(ctx context.Context, target string) (net.Conn, error) {
	c, err := d.get()
	if err != nil {
		return nil, err
	}
	type res struct {
		c   net.Conn
		err error
	}
	ch := make(chan res, 1)
	go func() {
		conn, err := c.TCP(target)
		ch <- res{conn, err}
	}()
	// A handshake takes about three round trips; a path with a long round trip
	// needs a few seconds, a network that drops UDP never answers.
	wait := 8 * time.Second
	if dl, ok := ctx.Deadline(); ok && time.Until(dl) < wait {
		wait = time.Until(dl)
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case r := <-ch:
		if r.err != nil {
			var de hyerrors.DialError
			if errors.As(r.err, &de) {
				return nil, errTargetRefused{de.Message}
			}
			return nil, r.err
		}
		return r.c, nil
	case <-timer.C:
	case <-ctx.Done():
	}
	go func() {
		if r := <-ch; r.c != nil {
			r.c.Close()
		}
	}()
	return nil, fmt.Errorf("Hysteria2 连接超时（网络可能不放行 UDP）")
}

func (d *hy2Dialer) Close() {
	d.mu.Lock()
	c := d.client
	d.client = nil
	d.mu.Unlock()
	if c != nil {
		// Close waits for a connection attempt in progress; nobody waits for it.
		go c.Close()
	}
}

// salamanderFactory gives the Hysteria2 client a UDP socket whose packets are
// obfuscated with Salamander: each packet is XORed with BLAKE2b-256 of the
// pre-shared key and an 8-byte random salt, and the salt is put in front.
type salamanderFactory struct{ psk []byte }

func (f salamanderFactory) New(net.Addr) (net.PacketConn, error) {
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	return newSalamander(pc, f.psk), nil
}

const salamanderSalt = 8

type salamanderConn struct {
	net.PacketConn
	psk []byte
}

func newSalamander(pc net.PacketConn, psk []byte) *salamanderConn {
	return &salamanderConn{PacketConn: pc, psk: append([]byte(nil), psk...)}
}

func (c *salamanderConn) key(salt []byte) [blake2b.Size256]byte {
	in := make([]byte, 0, len(c.psk)+salamanderSalt)
	in = append(in, c.psk...)
	in = append(in, salt...)
	return blake2b.Sum256(in)
}

func (c *salamanderConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	out := make([]byte, salamanderSalt+len(p))
	if _, err := rand.Read(out[:salamanderSalt]); err != nil {
		return 0, err
	}
	k := c.key(out[:salamanderSalt])
	for i, b := range p {
		out[salamanderSalt+i] = b ^ k[i%len(k)]
	}
	if _, err := c.PacketConn.WriteTo(out, addr); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *salamanderConn) ReadFrom(p []byte) (int, net.Addr, error) {
	buf := make([]byte, salamanderSalt+len(p))
	for {
		n, addr, err := c.PacketConn.ReadFrom(buf)
		if err != nil {
			return 0, nil, err
		}
		if n <= salamanderSalt {
			continue // too short to be one of ours: drop it
		}
		k := c.key(buf[:salamanderSalt])
		m := n - salamanderSalt
		for i := 0; i < m; i++ {
			p[i] = buf[salamanderSalt+i] ^ k[i%len(k)]
		}
		return m, addr, nil
	}
}
