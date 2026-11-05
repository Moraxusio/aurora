// Package p2p brings a client and an agent together without the VPS in the
// data path. The relay only carries a short offer/answer exchange; then both
// sides send small UDP packets at each other (opening the stateful firewalls
// and NATs in between) and run QUIC over the path that works, while the agent
// also tries to reach the client over TCP. Whatever connects first carries the
// usual Hello + token + yamux session, exactly like a forward direct link.
package p2p

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/apernet/quic-go"
)

// Op is the agent operation that starts a meeting (sent through the relay).
const Op = "link.punch"

// ALPN marks Aurora's QUIC links.
const ALPN = "aurora-p2p/1"

// Offer is what the client sends the agent through the relay.
type Offer struct {
	Target string   `json:"target,omitempty"` // agent id: the relay passes the offer to it
	Nonce  string   `json:"nonce"`            // hex, 16 bytes: proves punch packets come from the peer
	UDP    []string `json:"udp,omitempty"`    // client UDP candidates (host:port)
	TCP    []string `json:"tcp,omitempty"`    // client TCP listeners the agent may dial
}

// Answer is the agent's reply: where its UDP socket can be reached.
type Answer struct {
	UDP []string `json:"udp,omitempty"`
}

// Report ends the agent's side of a meeting (informational).
type Report struct {
	Via   string `json:"via,omitempty"` // quic | tcp
	Addr  string `json:"addr,omitempty"`
	Error string `json:"error,omitempty"`
}

// Packet kinds: who sent a punch packet. A side only accepts the other kind,
// so its own packets reflected back do not count.
const (
	KindClient byte = 'c'
	KindAgent  byte = 'a'
)

const (
	pktLen   = 4 + 16
	maxPeers = 8
	// MaxCandidates bounds what one offer may make the agent contact.
	MaxCandidates = 16
)

// NewNonce returns a fresh random meeting nonce.
func NewNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Debug receives diagnostic lines from the punch reader (set by the client per meeting).
var Debug = func(format string, args ...any) {}

func packet(kind byte, nonce []byte) []byte {
	// First byte 0x00: quic-go hands packets whose two top bits are clear to
	// ReadNonQUICPacket instead of its connections.
	p := make([]byte, 0, pktLen)
	p = append(p, 0x00, 'A', 'P', kind)
	return append(p, nonce...)
}

// QUICConfig is used by both ends: keep-alives every 5 s hold firewall and
// NAT pinholes open and let a silent path be noticed; the windows suit a
// ~200 ms path; one stream per operation needs a high stream limit.
func QUICConfig() *quic.Config {
	return &quic.Config{
		HandshakeIdleTimeout:           6 * time.Second,
		MaxIdleTimeout:                 25 * time.Second,
		KeepAlivePeriod:                5 * time.Second,
		MaxIncomingStreams:             1024,
		InitialStreamReceiveWindow:     2 << 20,
		MaxStreamReceiveWindow:         16 << 20,
		InitialConnectionReceiveWindow: 4 << 20,
		MaxConnectionReceiveWindow:     32 << 20,
	}
}

// ServerTLS is the agent's QUIC TLS (its usual certificate).
func ServerTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13, NextProtos: []string{ALPN}}
}

// ClientTLS adds the ALPN to a pinned client config.
func ClientTLS(pinned *tls.Config) *tls.Config {
	c := pinned.Clone()
	c.NextProtos = []string{ALPN}
	c.ServerName = "aurora"
	return c
}

// Endpoint is one UDP socket used for punching, STUN and QUIC. It lives as
// long as a QUIC link made on it does.
type Endpoint struct {
	UDP *net.UDPConn
	Tr  *quic.Transport

	kind  byte
	nonce []byte

	mu      sync.Mutex
	targets map[string]*net.UDPAddr
	peers   map[string]bool
	onPeer  func(*net.UDPAddr)
	stun    map[[12]byte]chan *net.UDPAddr
	holds   int
	done    bool
	closed  bool
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	reading bool
	pending []*net.UDPAddr
	wake    chan struct{}
}

// Open binds a dual-stack UDP socket, on port if it is free (0: any).
func Open(port int, nonce string, kind byte) (*Endpoint, error) {
	nb, err := hex.DecodeString(nonce)
	if err != nil || len(nb) != 16 {
		return nil, errors.New("无效的打洞随机数")
	}
	var uc *net.UDPConn
	if port != 0 {
		uc, _ = net.ListenUDP("udp", &net.UDPAddr{Port: port})
	}
	if uc == nil {
		if uc, err = net.ListenUDP("udp", &net.UDPAddr{}); err != nil {
			return nil, err
		}
	}
	e := &Endpoint{UDP: uc, Tr: &quic.Transport{Conn: uc}, kind: kind, nonce: nb,
		targets: map[string]*net.UDPAddr{}, peers: map[string]bool{}, stun: map[[12]byte]chan *net.UDPAddr{}, wake: make(chan struct{}, 1)}
	return e, nil
}

// Port is the local UDP port.
func (e *Endpoint) Port() int { return e.UDP.LocalAddr().(*net.UDPAddr).Port }

var candidateAllowed = func(ap netip.AddrPort, local []netip.Prefix) bool { return AllowedCandidate(ap, local) }

// AddTargets adds addresses to punch at (host:port strings; bad ones are skipped).
func (e *Endpoint) AddTargets(addrs []string) {
	local := LocalPrefixes()
	for i, a := range addrs {
		if i >= MaxCandidates {
			break
		}
		ua, err := net.ResolveUDPAddr("udp", a)
		ap, err := netip.ParseAddrPort(a)
		if err != nil || !candidateAllowed(ap, local) {
			continue
		}
		e.addTarget(ua)
	}
}

func (e *Endpoint) addTarget(ua *net.UDPAddr) {
	e.mu.Lock()
	if len(e.targets) < MaxCandidates+maxPeers {
		e.targets[canon(ua)] = ua
	}
	e.mu.Unlock()
	select {
	case e.wake <- struct{}{}:
	default:
	}
}

func canon(a *net.UDPAddr) string {
	ip := a.IP
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return (&net.UDPAddr{IP: ip, Port: a.Port, Zone: a.Zone}).String()
}

// Start runs the reader and the punch sender until ctx ends. onPeer is called
// once per address a valid packet of the other side came from.
func (e *Endpoint) Start(ctx context.Context, onPeer func(*net.UDPAddr)) {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return
	}
	if e.cancel == nil {
		e.ctx, e.cancel = context.WithCancel(ctx)
	}
	ctx = e.ctx
	e.onPeer = onPeer
	pend := e.pending
	e.pending = nil
	reading := e.reading
	e.reading = true
	e.mu.Unlock()
	if !reading {
		ready := make(chan struct{})
		e.wg.Add(1)
		go func() { defer e.wg.Done(); e.read(ctx, ready) }()
		<-ready
	}
	// Peers whose packets arrived before onPeer was set still get their dial.
	if onPeer != nil {
		for _, a := range pend {
			go onPeer(a)
		}
	}
	e.wg.Add(1)
	go func() { defer e.wg.Done(); e.send(ctx) }()
}

// StartReader runs only the reader (STUN before the offer goes out).
func (e *Endpoint) StartReader(ctx context.Context) {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return
	}
	if e.cancel == nil {
		e.ctx, e.cancel = context.WithCancel(ctx)
	}
	ctx = e.ctx
	e.reading = true
	e.mu.Unlock()
	ready := make(chan struct{})
	e.wg.Add(1)
	go func() { defer e.wg.Done(); e.read(ctx, ready) }()
	<-ready
}

func (e *Endpoint) read(ctx context.Context, ready chan struct{}) {
	buf := make([]byte, 1500)
	first := true
	for {
		rctx := ctx
		if first {
			// The first call creates quic-go's queue for non-QUIC packets.
			var cancel context.CancelFunc
			rctx, cancel = context.WithTimeout(ctx, time.Millisecond)
			_, _, _ = e.Tr.ReadNonQUICPacket(rctx, buf)
			cancel()
			close(ready)
			first = false
			continue
		}
		n, from, err := e.Tr.ReadNonQUICPacket(rctx, buf)
		if err != nil {
			return
		}
		ua, ok := from.(*net.UDPAddr)
		if !ok {
			continue
		}
		b := buf[:n]
		if n >= 20 && (b[0] == 0x01 && b[1] == 0x01) {
			e.stunResponse(b)
			continue
		}
		if n != pktLen || b[1] != 'A' || b[2] != 'P' || b[3] == e.kind || subtle.ConstantTimeCompare(b[4:], e.nonce) != 1 {
			continue
		}
		key := canon(ua)
		e.mu.Lock()
		isClosed := e.closed
		isNew := !e.peers[key] && len(e.peers) < maxPeers
		if isNew {
			e.peers[key] = true
		}
		cb := e.onPeer
		if isNew && cb == nil && len(e.pending) < maxPeers {
			// Start has not set onPeer yet: queue the peer so Start can dial it.
			e.pending = append(e.pending, ua)
		}
		e.mu.Unlock()
		if isClosed {
			return
		}
		if isNew {
			// Answer at once: for the peer this is a reply on the flow it opened.
			_, _ = e.Tr.WriteTo(packet(e.kind, e.nonce), ua)
			e.addTarget(ua)
			if cb != nil {
				go cb(ua)
			}
		}
	}
}

// send fires a burst every 100 ms for 2 s, then every 400 ms.
func (e *Endpoint) send(ctx context.Context) {
	p := packet(e.kind, e.nonce)
	start := time.Now()
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-e.wake:
		}
		e.mu.Lock()
		ts := make([]*net.UDPAddr, 0, len(e.targets))
		for _, a := range e.targets {
			ts = append(ts, a)
		}
		e.mu.Unlock()
		for _, a := range ts {
			_, _ = e.Tr.WriteTo(p, a)
		}
		d := 100 * time.Millisecond
		if time.Since(start) > 2*time.Second {
			d = 400 * time.Millisecond
		}
		if !t.Stop() {
			select {
			case <-t.C:
			default:
			}
		}
		t.Reset(d)
	}
}

// Hold keeps the endpoint open for a link made on it; call the result when
// that link ends.
func (e *Endpoint) Hold() func() {
	e.mu.Lock()
	e.holds++
	e.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			e.mu.Lock()
			e.holds--
			last := e.holds == 0 && e.done
			e.mu.Unlock()
			if last {
				e.Close()
			}
		})
	}
}

// Done ends the meeting: the endpoint closes now unless a link holds it.
func (e *Endpoint) Done() {
	e.mu.Lock()
	e.done = true
	idle := e.holds == 0
	e.mu.Unlock()
	if idle {
		e.Close()
	}
}

// Close closes the transport and the socket (and every QUIC link on it).
func (e *Endpoint) Close() {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		e.wg.Wait()
		return
	}
	e.closed = true
	cancel := e.cancel
	e.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	_ = e.Tr.Close()
	_ = e.UDP.Close()
	e.wg.Wait()
}
