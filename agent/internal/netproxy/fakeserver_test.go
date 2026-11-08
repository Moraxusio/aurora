package netproxy

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"hash/crc32"
	"hash/fnv"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/sha3"

	"aurora3/internal/wire"
)

// The servers below read each protocol the way its specification describes,
// written separately from the dialers in this package: a dialer and a server
// that share a mistake would agree with each other and a real server would
// still refuse the dialer. They echo the payload back and record the
// destination they were asked for.

type fakeServer struct {
	ln net.Listener

	mu      sync.Mutex
	target  string
	rejects int
}

func (f *fakeServer) got() string  { f.mu.Lock(); defer f.mu.Unlock(); return f.target }
func (f *fakeServer) set(s string) { f.mu.Lock(); f.target = s; f.mu.Unlock() }
func (f *fakeServer) addr() string { return f.ln.Addr().String() }

func (f *fakeServer) accept(handle func(net.Conn)) {
	for {
		c, err := f.ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			_ = c.SetDeadline(time.Now().Add(15 * time.Second))
			handle(c)
		}()
	}
}

func listenTLS(t *testing.T) (*fakeServer, string) {
	t.Helper()
	cert, pin, err := wire.LoadOrCreateCert(t.TempDir(), "node")
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return &fakeServer{ln: ln}, pin
}

func listenTCP(t *testing.T) *fakeServer {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return &fakeServer{ln: ln}
}

func nodeAt(proto, addr string) Node {
	host, portStr, _ := net.SplitHostPort(addr)
	port, _ := atoiPort(portStr)
	return Node{Proto: proto, Host: host, Port: port}
}

// readAddrPortFirst reads the VLESS/VMess destination: port, type, address.
func readAddrPortFirst(r io.Reader) (string, error) {
	var pb [2]byte
	if _, err := io.ReadFull(r, pb[:]); err != nil {
		return "", err
	}
	port := int(binary.BigEndian.Uint16(pb[:]))
	var t [1]byte
	if _, err := io.ReadFull(r, t[:]); err != nil {
		return "", err
	}
	var host string
	switch t[0] {
	case 1:
		b := make([]byte, 4)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", err
		}
		host = net.IP(b).String()
	case 3:
		b := make([]byte, 16)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", err
		}
		host = net.IP(b).String()
	case 2:
		var l [1]byte
		if _, err := io.ReadFull(r, l[:]); err != nil {
			return "", err
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(r, b); err != nil {
			return "", err
		}
		host = string(b)
	default:
		return "", fmt.Errorf("address type %d", t[0])
	}
	return net.JoinHostPort(host, fmt.Sprint(port)), nil
}

// serveVLESS answers one VLESS request for the user with uuid.
func serveVLESS(f *fakeServer, uuid [16]byte) func(net.Conn) {
	return func(c net.Conn) {
		br := bufio.NewReader(c)
		var head [1 + 16 + 1]byte
		if _, err := io.ReadFull(br, head[:]); err != nil {
			return
		}
		if head[0] != 0 || string(head[1:17]) != string(uuid[:]) {
			f.mu.Lock()
			f.rejects++
			f.mu.Unlock()
			return
		}
		if _, err := io.CopyN(io.Discard, br, int64(head[17])); err != nil { // addons
			return
		}
		cmd, err := br.ReadByte()
		if err != nil || cmd != 1 {
			return
		}
		target, err := readAddrPortFirst(br)
		if err != nil {
			return
		}
		f.set(target)
		if _, err := c.Write([]byte{0x00, 0x00}); err != nil { // version, no addons
			return
		}
		_, _ = io.Copy(c, br)
	}
}

// ---- VMess server side (AEAD form) ----

func kdf(key []byte, path ...string) []byte {
	mk := func() hash.Hash { return hmac.New(sha256.New, []byte("VMess AEAD KDF")) }
	for _, p := range path {
		parent, v := mk, []byte(p)
		mk = func() hash.Hash { return hmac.New(parent, v) }
	}
	h := mk()
	h.Write(key)
	return h.Sum(nil)
}

func gcm(t error, key []byte) cipher.AEAD {
	b, _ := aes.NewCipher(key)
	a, _ := cipher.NewGCM(b)
	return a
}

// serveVMess opens the request the way a VMess server does, checks the header
// checksum, answers with a sealed response header and echoes the body in
// chunks.
func serveVMess(f *fakeServer, uuid [16]byte, now func() time.Time) func(net.Conn) {
	h := md5.New()
	h.Write(uuid[:])
	h.Write([]byte("c48619fe-8f02-49e0-b9e9-edf763e17e21"))
	cmdKey := h.Sum(nil)
	return func(c net.Conn) {
		var authID [16]byte
		if _, err := io.ReadFull(c, authID[:]); err != nil {
			return
		}
		blk, _ := aes.NewCipher(kdf(cmdKey, "AES Auth ID Encryption")[:16])
		var plain [16]byte
		blk.Decrypt(plain[:], authID[:])
		ts := int64(binary.BigEndian.Uint64(plain[:8]))
		if crc32.ChecksumIEEE(plain[:12]) != binary.BigEndian.Uint32(plain[12:]) {
			f.mu.Lock()
			f.rejects++
			f.mu.Unlock()
			return
		}
		if d := now().Unix() - ts; d > 120 || d < -120 {
			f.mu.Lock()
			f.rejects++
			f.mu.Unlock()
			return
		}
		var encLen [18]byte
		var nonce [8]byte
		if _, err := io.ReadFull(c, encLen[:]); err != nil {
			return
		}
		if _, err := io.ReadFull(c, nonce[:]); err != nil {
			return
		}
		lb, err := gcm(nil, kdf(cmdKey, "VMess Header AEAD Key_Length", string(authID[:]), string(nonce[:]))[:16]).
			Open(nil, kdf(cmdKey, "VMess Header AEAD Nonce_Length", string(authID[:]), string(nonce[:]))[:12], encLen[:], authID[:])
		if err != nil {
			return
		}
		body := make([]byte, int(binary.BigEndian.Uint16(lb))+16)
		if _, err := io.ReadFull(c, body); err != nil {
			return
		}
		hdr, err := gcm(nil, kdf(cmdKey, "VMess Header AEAD Key", string(authID[:]), string(nonce[:]))[:16]).
			Open(nil, kdf(cmdKey, "VMess Header AEAD Nonce", string(authID[:]), string(nonce[:]))[:12], body, authID[:])
		if err != nil {
			return
		}
		// header: ver, iv16, key16, V, opt, padlen|sec, 0, cmd, port, type, addr, padding, fnv32
		if len(hdr) < 1+16+16+1+1+1+1+1+4 || hdr[0] != 1 {
			return
		}
		sum := fnv.New32a()
		sum.Write(hdr[:len(hdr)-4])
		if sum.Sum32() != binary.BigEndian.Uint32(hdr[len(hdr)-4:]) {
			return
		}
		var iv, key [16]byte
		copy(iv[:], hdr[1:17])
		copy(key[:], hdr[17:33])
		respV, opt, ps := hdr[33], hdr[34], hdr[35]
		padLen, sec := int(ps>>4), ps&0x0f
		if hdr[37] != 1 {
			return
		}
		target, err := readAddrPortFirst(bytesReader(hdr[38 : len(hdr)-4-padLen]))
		if err != nil {
			return
		}
		f.set(target)
		if opt&0x01 == 0 || opt&0x04 == 0 {
			return // this server only does the chunked, masked body
		}
		reqAEAD, respAEAD := vmessBodyAEAD(sec, key[:]), vmessBodyAEAD(sec, sha(key[:]))
		respIV := sha(iv[:])
		respKey := sha(key[:])

		// response header: [V, opt=0, cmd=0, cmdlen=0] sealed with the response keys
		rh := []byte{respV, 0, 0, 0}
		lk := gcm(nil, kdf(respKey, "AEAD Resp Header Len Key")[:16])
		var rl [2]byte
		binary.BigEndian.PutUint16(rl[:], uint16(len(rh)))
		out := lk.Seal(nil, kdf(respIV, "AEAD Resp Header Len IV")[:12], rl[:], nil)
		pk := gcm(nil, kdf(respKey, "AEAD Resp Header Key")[:16])
		out = pk.Seal(out, kdf(respIV, "AEAD Resp Header IV")[:12], rh, nil)
		if _, err := c.Write(out); err != nil {
			return
		}

		reqMask := sha3.NewShake128()
		reqMask.Write(iv[:])
		respMask := sha3.NewShake128()
		respMask.Write(respIV)
		next := func(s sha3.ShakeHash) uint16 {
			var b [2]byte
			s.Read(b[:])
			return binary.BigEndian.Uint16(b[:])
		}
		var rc, wc uint16
		mkNonce := func(base []byte, n uint16) []byte {
			b := make([]byte, 12)
			copy(b, base[:12])
			binary.BigEndian.PutUint16(b, n)
			return b
		}
		for {
			var sz [2]byte
			if _, err := io.ReadFull(c, sz[:]); err != nil {
				return
			}
			pad := int(next(reqMask) % 64)
			size := int(next(reqMask) ^ binary.BigEndian.Uint16(sz[:]))
			chunk := make([]byte, size)
			if _, err := io.ReadFull(c, chunk); err != nil {
				return
			}
			if size == reqAEAD.Overhead()+pad {
				// end of stream: say so back and stop
				p := int(next(respMask) % 64)
				var s [2]byte
				binary.BigEndian.PutUint16(s[:], next(respMask)^uint16(respAEAD.Overhead()+p))
				_, _ = c.Write(append(append(s[:], respAEAD.Seal(nil, mkNonce(respIV, wc), nil, nil)...), make([]byte, p)...))
				return
			}
			pt, err := reqAEAD.Open(nil, mkNonce(iv[:], rc), chunk[:size-pad], nil)
			if err != nil {
				return
			}
			rc++
			p := int(next(respMask) % 64)
			mask := next(respMask)
			var s [2]byte
			binary.BigEndian.PutUint16(s[:], mask^uint16(len(pt)+respAEAD.Overhead()+p))
			reply := append(s[:], respAEAD.Seal(nil, mkNonce(respIV, wc), pt, nil)...)
			wc++
			reply = append(reply, make([]byte, p)...)
			if _, err := c.Write(reply); err != nil {
				return
			}
		}
	}
}

func sha(b []byte) []byte { s := sha256.Sum256(b); return s[:16] }

func vmessBodyAEAD(sec byte, key []byte) cipher.AEAD {
	if sec == 4 {
		var k [32]byte
		a := md5.Sum(key)
		copy(k[:16], a[:])
		b := md5.Sum(k[:16])
		copy(k[16:], b[:])
		c, _ := chacha20poly1305.New(k[:])
		return c
	}
	return gcm(nil, key)
}

type bytesRdr struct{ b []byte }

func bytesReader(b []byte) io.Reader { return &bytesRdr{b} }
func (r *bytesRdr) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}

var errUnused = errors.New("unused")
