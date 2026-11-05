package netproxy

import (
	"context"
	"crypto/subtle"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	hyclient "github.com/apernet/hysteria/core/v2/client"
	hyerrors "github.com/apernet/hysteria/core/v2/errors"

	"aurora3/internal/wire"
)

// Hy2 is a Hysteria 2 entry point on the VPS. It carries the sessions'
// connections as streams of one QUIC connection over UDP.
//
// It exists for speed. The path from the campus network to the VPS loses
// packets and has a ~210 ms round trip; every TCP connection there tops out
// around 1-2 MB/s however the ends are tuned, while QUIC with Hysteria's
// congestion control fills the link. Trojan over TCP stays as the fallback
// for networks that drop UDP.
type Hy2 struct {
	Addr     string `json:"addr"` // "[2607:...]:443"
	Password string `json:"password"`
	SNI      string `json:"sni,omitempty"`
	Pin      string `json:"pin"` // hex SHA-256 of the server certificate
	// DownMbps/UpMbps announce the link speed so the server can send at that
	// rate (Hysteria's "brutal" mode). 0 lets both ends use BBR instead.
	DownMbps int `json:"down_mbps,omitempty"`
	UpMbps   int `json:"up_mbps,omitempty"`
}

// Valid reports whether the entry point is complete. A pin is required: the
// transport never runs without certificate verification.
func (h *Hy2) Valid() bool {
	return h != nil && strings.TrimSpace(h.Addr) != "" && len(h.Password) >= 16 && len(strings.TrimSpace(h.Pin)) == 64
}

// hyTransport owns the long-lived QUIC connection and decides when to stop
// trying it.
type hyTransport struct {
	cfg Hy2
	log *log.Logger

	mu        sync.Mutex
	client    hyclient.Client
	downUntil time.Time
	failures  int
}

func newHyTransport(cfg *Hy2, logger *log.Logger) *hyTransport {
	if !cfg.Valid() {
		return nil
	}
	return &hyTransport{cfg: *cfg, log: logger}
}

// errTargetRefused means the VPS reached the far side and it said no: retrying
// over Trojan would only repeat the same answer more slowly.
type errTargetRefused struct{ msg string }

func (e errTargetRefused) Error() string { return "目标拒绝连接：" + e.msg }

func (t *hyTransport) usable() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return time.Now().After(t.downUntil)
}

// markDown backs off after a transport failure: 30 s, then doubling up to
// 10 min, so a network without UDP costs one timeout now and then rather than
// one per connection.
func (t *hyTransport) markDown(err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.failures++
	back := 30 * time.Second << min(t.failures-1, 4)
	t.downUntil = time.Now().Add(back)
	if c := t.client; c != nil {
		// Close waits for a connection attempt still in progress; that wait
		// must not hold up the Trojan fallback.
		go c.Close()
		t.client = nil
	}
	if t.log != nil {
		t.log.Printf("Hysteria2 不可用（%v），%s 内改走 Trojan", err, back)
	}
}

func (t *hyTransport) ok() {
	t.mu.Lock()
	t.failures = 0
	t.mu.Unlock()
}

func (t *hyTransport) get() (hyclient.Client, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.client != nil {
		return t.client, nil
	}
	c, err := hyclient.NewReconnectableClient(t.config, nil, true)
	if err != nil {
		return nil, err
	}
	t.client = c
	return c, nil
}

func (t *hyTransport) config() (*hyclient.Config, error) {
	addr, err := net.ResolveUDPAddr("udp", t.cfg.Addr)
	if err != nil {
		return nil, err
	}
	want := strings.ToLower(strings.TrimSpace(t.cfg.Pin))
	sni := t.cfg.SNI
	if sni == "" {
		sni, _, _ = net.SplitHostPort(t.cfg.Addr)
	}
	return &hyclient.Config{
		ServerAddr: addr,
		Auth:       t.cfg.Password,
		TLSConfig: hyclient.TLSConfig{
			ServerName: sni,
			// The pin replaces chain validation, as for the Trojan upstream: a
			// self-signed certificate is fine, any other certificate is not.
			InsecureSkipVerify: true,
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 || subtle.ConstantTimeCompare([]byte(wire.CertPin(raw[0])), []byte(want)) != 1 {
					return wire.ErrPinMismatch
				}
				return nil
			},
		},
		BandwidthConfig: hyclient.BandwidthConfig{
			MaxTx: uint64(t.cfg.UpMbps) * 125000,
			MaxRx: uint64(t.cfg.DownMbps) * 125000,
		},
	}, nil
}

// dial opens a stream to target. The library call has no context, so the
// wait is bounded here and a late connection is closed.
func (t *hyTransport) dial(ctx context.Context, target string) (net.Conn, error) {
	c, err := t.get()
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
	// A handshake to the VPS takes about three round trips (~0.7 s). Waiting
	// longer than this only delays the Trojan fallback on networks without UDP.
	wait := 4 * time.Second
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
		t.ok()
		return r.c, nil
	case <-timer.C:
	case <-ctx.Done():
	}
	go func() {
		if r := <-ch; r.c != nil {
			r.c.Close()
		}
	}()
	return nil, fmt.Errorf("Hysteria2 连接超时")
}

// TestHy2 opens one stream to target through h, for the CLI self-test.
func TestHy2(ctx context.Context, h *Hy2, target string) error {
	t := newHyTransport(h, nil)
	if t == nil {
		return errors.New("没有配置 Hysteria2")
	}
	defer t.close()
	c, err := t.dial(ctx, target)
	if err != nil {
		return err
	}
	return c.Close()
}

func (t *hyTransport) close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.client != nil {
		_ = t.client.Close()
		t.client = nil
	}
}
