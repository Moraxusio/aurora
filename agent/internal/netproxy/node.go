package netproxy

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/wire"
)

// Node protocol names, as the client writes them (D-86).
const (
	ProtoTrojan = "trojan"
	ProtoHy2    = "hysteria2"
	ProtoVLESS  = "vless"
	ProtoVMess  = "vmess"
)

// Node is one outbound server the proxy can leave through: a line of a
// subscription, or the user's own VPS. It carries everything needed to dial,
// and nothing about where it came from (D-84): the agent holds the chosen
// node, never the subscription.
type Node struct {
	Name  string `json:"name,omitempty"`
	Proto string `json:"proto"`
	Host  string `json:"host"`
	Port  int    `json:"port"`

	// Secret is the password (Trojan, Hysteria2) or the UUID (VLESS, VMess).
	Secret string `json:"secret,omitempty"`

	TLS TLSMode `json:"tls"`

	// Transport is "tcp" (default) or "ws". Other transports are refused when
	// the node is checked, so a node never silently falls back to a different
	// one than the provider configured (D-87).
	Transport string `json:"transport,omitempty"`
	WSPath    string `json:"ws_path,omitempty"`
	WSHost    string `json:"ws_host,omitempty"`

	// VMess: the body cipher. Empty means auto.
	Cipher string `json:"cipher,omitempty"`
	// VLESS: only the empty flow is supported. Vision is refused.
	Flow string `json:"flow,omitempty"`

	// Hysteria2 extras.
	Obfs         string `json:"obfs,omitempty"` // "salamander" or ""
	ObfsPassword string `json:"obfs_password,omitempty"`
	UpMbps       int    `json:"up_mbps,omitempty"`
	DownMbps     int    `json:"down_mbps,omitempty"`

	// Unsupported is set by the client's parser when the subscription line uses
	// something this struct cannot express (Reality, port hopping, a plugin).
	// Such a node would otherwise look like a plain one and connect the wrong
	// way, so Check reports the reason and the node is never dialled.
	Unsupported string `json:"unsupported,omitempty"`
}

// TLSMode is how the server's certificate is checked (D-88). Exactly one of
// the three applies; a node with none of them is refused.
type TLSMode struct {
	// Enabled turns TLS on. Trojan and Hysteria2 always use TLS.
	Enabled bool `json:"enabled"`
	// SNI is the server name sent and, unless Pin or Insecure is set, the name
	// the certificate must be valid for. Empty means the node's host.
	SNI string `json:"sni,omitempty"`
	// Pin is the hex SHA-256 of the server's certificate: for a server whose
	// certificate no authority signed, such as the user's own VPS.
	Pin string `json:"pin,omitempty"`
	// Insecure skips verification. It exists because providers mark such nodes
	// (skip-cert-verify) and the user may still choose them; the client shows it.
	Insecure bool `json:"insecure,omitempty"`
	// ALPN protocols to offer.
	ALPN []string `json:"alpn,omitempty"`
}

// Addr is the host:port to dial.
func (n Node) Addr() string { return net.JoinHostPort(n.Host, strconv.Itoa(n.Port)) }

// Label is the node's name for logs and status. It never contains a secret.
func (n Node) Label() string {
	name := n.Name
	if name == "" {
		name = n.Addr()
	}
	return n.Proto + "://" + name
}

// Check reports why the node cannot be used, or nil. The messages are shown to
// the user, so they say what to change.
func (n Node) Check() error {
	if n.Unsupported != "" {
		return errors.New(n.Unsupported)
	}
	if strings.TrimSpace(n.Host) == "" || n.Port < 1 || n.Port > 65535 {
		return errors.New("节点缺少地址或端口")
	}
	switch n.Proto {
	case ProtoTrojan:
		if n.Secret == "" {
			return errors.New("Trojan 节点缺少密码")
		}
	case ProtoHy2:
		if n.Secret == "" {
			return errors.New("Hysteria2 节点缺少密码")
		}
		if n.Obfs != "" && n.Obfs != "salamander" {
			return fmt.Errorf("Hysteria2 的混淆 %q 暂不支持", n.Obfs)
		}
		if n.Obfs == "salamander" && len(n.ObfsPassword) < 4 {
			return errors.New("Hysteria2 的 salamander 混淆密码太短")
		}
	case ProtoVLESS, ProtoVMess:
		if _, err := parseUUID(n.Secret); err != nil {
			return fmt.Errorf("%s 节点的 UUID 无效", strings.ToUpper(n.Proto))
		}
		if n.Flow != "" {
			return fmt.Errorf("VLESS 流控 %q 暂不支持（需要 XTLS Vision）", n.Flow)
		}
		if n.Transport != "" && n.Transport != "tcp" && n.Transport != "ws" {
			return fmt.Errorf("传输方式 %q 暂不支持（支持 tcp、ws）", n.Transport)
		}
		if n.Proto == ProtoVMess {
			if _, err := vmessSecurity(n.Cipher); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("协议 %q 暂不支持", n.Proto)
	}
	if n.Proto == ProtoTrojan || n.Proto == ProtoHy2 {
		if n.Transport != "" && n.Transport != "tcp" {
			return fmt.Errorf("%s 不支持传输方式 %q", n.Proto, n.Transport)
		}
	}
	// Every protocol except plain VLESS/VMess rides on TLS; for those two the
	// user may choose none, which is how some providers run them behind a CDN.
	if n.tlsRequired() && !n.TLS.Enabled {
		return fmt.Errorf("%s 必须使用 TLS", n.Proto)
	}
	if n.TLS.Enabled && n.TLS.Pin != "" && len(strings.TrimSpace(n.TLS.Pin)) != 64 {
		return errors.New("证书指纹应为 64 位十六进制")
	}
	return nil
}

func (n Node) tlsRequired() bool { return n.Proto == ProtoTrojan || n.Proto == ProtoHy2 }

// tlsConfig builds the client TLS settings for the three verification modes.
func (n Node) tlsConfig() *tls.Config {
	m := n.TLS
	sni := m.SNI
	if sni == "" {
		sni = n.Host
	}
	cfg := &tls.Config{ServerName: sni, MinVersion: tls.VersionTLS12, NextProtos: m.ALPN}
	switch {
	case m.Pin != "":
		want := strings.ToLower(strings.TrimSpace(m.Pin))
		// The pin replaces chain validation, so a self-signed certificate is
		// fine and a different one is not.
		cfg.InsecureSkipVerify = true
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return wire.ErrPinMismatch
			}
			if subtle.ConstantTimeCompare([]byte(wire.CertPin(cs.PeerCertificates[0].Raw)), []byte(want)) != 1 {
				return wire.ErrPinMismatch
			}
			return nil
		}
	case m.Insecure:
		cfg.InsecureSkipVerify = true
	}
	// Neither pin nor insecure: the system roots and the server name decide.
	return cfg
}

// hyVerify is tlsConfig's rule in the shape the Hysteria2 client takes.
func (n Node) hyVerify() (skip bool, verify func([][]byte, [][]*x509.Certificate) error) {
	m := n.TLS
	switch {
	case m.Pin != "":
		want := strings.ToLower(strings.TrimSpace(m.Pin))
		return true, func(raw [][]byte, _ [][]*x509.Certificate) error {
			if len(raw) == 0 || subtle.ConstantTimeCompare([]byte(wire.CertPin(raw[0])), []byte(want)) != 1 {
				return wire.ErrPinMismatch
			}
			return nil
		}
	case m.Insecure:
		return true, nil
	}
	return false, nil
}

// dialer opens a tunnel to a target through one node.
type dialer interface {
	DialContext(ctx context.Context, target string) (net.Conn, error)
	Close()
}

// newDialer builds the dialer for a node. The node must have passed Check.
func newDialer(n Node, timeout time.Duration, logf func(string, ...any)) (dialer, error) {
	if err := n.Check(); err != nil {
		return nil, err
	}
	switch n.Proto {
	case ProtoTrojan:
		return &trojanDialer{n: n, timeout: timeout}, nil
	case ProtoHy2:
		return newHy2Dialer(n, logf), nil
	case ProtoVLESS:
		return &vlessDialer{n: n, timeout: timeout}, nil
	case ProtoVMess:
		return &vmessDialer{n: n, timeout: timeout}, nil
	}
	return nil, fmt.Errorf("协议 %q 暂不支持", n.Proto)
}

// Probe opens one tunnel to target through n and closes it again. It is what
// "test this node" means: the node answered, accepted the credentials, and
// reached the target. The node is not saved and no proxy is involved.
func Probe(ctx context.Context, n Node, target string) error {
	d, err := newDialer(n, 8*time.Second, nil)
	if err != nil {
		return err
	}
	defer d.Close()
	c, err := d.DialContext(ctx, target)
	if err != nil {
		return err
	}
	defer c.Close()
	// Trojan and VLESS accept the request without answering until there is
	// payload, so a connection that opened only proves the TCP/TLS part.
	// Send a request the target answers, and wait for the first byte.
	if _, err := c.Write([]byte("GET / HTTP/1.0\r\nHost: " + hostOnly(target) + "\r\nConnection: close\r\n\r\n")); err != nil {
		return err
	}
	_ = c.SetReadDeadline(time.Now().Add(8 * time.Second))
	var b [1]byte
	if _, err := c.Read(b[:]); err != nil {
		return fmt.Errorf("节点已连上，但目标没有回应：%w", err)
	}
	return nil
}

func hostOnly(target string) string {
	h, _, err := net.SplitHostPort(target)
	if err != nil {
		return target
	}
	return h
}

// splitTarget parses "host:port" into the pieces every protocol header needs.
func splitTarget(target string) (host string, port int, err error) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return "", 0, fmt.Errorf("目标地址无效：%w", err)
	}
	port, ok := atoiPort(portStr)
	if !ok {
		return "", 0, errors.New("目标端口无效")
	}
	if len(host) > 255 {
		return "", 0, errors.New("目标域名过长")
	}
	return host, port, nil
}

// appendSocksAddr appends a destination in the SOCKS5 address layout, which
// Trojan uses as is: a type byte, the address, then the port.
func appendSocksAddr(out []byte, host string, port int) []byte {
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			out = append(out, 0x01)
			out = append(out, v4...)
		} else {
			out = append(out, 0x04)
			out = append(out, ip.To16()...)
		}
	} else {
		out = append(out, 0x03, byte(len(host)))
		out = append(out, host...)
	}
	return append(out, byte(port>>8), byte(port))
}
