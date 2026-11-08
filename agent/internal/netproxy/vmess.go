package netproxy

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"hash/crc32"
	"hash/fnv"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/sha3"
)

// VMess, the AEAD form that every maintained server accepts (the older MD5
// form is not offered). A request is one sealed header followed by chunks;
// a response is a sealed header followed by chunks. The layout follows the
// protocol description at v2fly.org/developer/protocols/vmess, and the cipher
// constants are the ones both v2fly and Xray servers use, checked against a
// real Xray server in the interop test.

const (
	vmessVersion = 1

	vmessOptChunkStream  = 0x01
	vmessOptChunkMasking = 0x04
	vmessOptPadding      = 0x08

	vmessSecAES128GCM = 3
	vmessSecChaCha    = 4

	// vmessChunk is the payload size of one chunk: the 8 KiB buffer Xray and
	// v2fly use, less the tag, the size field and the largest padding.
	vmessChunk = 8192 - 16 - 2 - 64
)

// vmessSecurity maps a cipher name from a subscription to the header value.
func vmessSecurity(name string) (byte, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "", "auto", "aes-128-gcm":
		return vmessSecAES128GCM, nil
	case "chacha20-poly1305":
		return vmessSecChaCha, nil
	}
	return 0, fmt.Errorf("VMess 加密方式 %q 暂不支持（支持 auto、aes-128-gcm、chacha20-poly1305）", name)
}

// vmessKDF is the nested HMAC-SHA256 the AEAD form derives every key from.
func vmessKDF(key []byte, path ...string) []byte {
	creator := func() hash.Hash { return hmac.New(sha256.New, []byte("VMess AEAD KDF")) }
	for _, p := range path {
		parent, v := creator, []byte(p)
		creator = func() hash.Hash { return hmac.New(parent, v) }
	}
	h := creator()
	h.Write(key)
	return h.Sum(nil)
}

func vmessKDF16(key []byte, path ...string) []byte { return vmessKDF(key, path...)[:16] }

func gcmOf(key []byte) (cipher.AEAD, error) {
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

// vmessCmdKey is MD5(uuid + the protocol's fixed string).
func vmessCmdKey(id [16]byte) [16]byte {
	h := md5.New()
	h.Write(id[:])
	h.Write([]byte("c48619fe-8f02-49e0-b9e9-edf763e17e21"))
	var out [16]byte
	h.Sum(out[:0])
	return out
}

// sealVMessHeader builds EAuID || sealed length || nonce || sealed header.
func sealVMessHeader(cmdKey [16]byte, header []byte, now time.Time) ([]byte, error) {
	// EAuID: time, 4 random bytes and their CRC, in one AES block.
	var plain [16]byte
	binary.BigEndian.PutUint64(plain[:8], uint64(now.Unix()))
	if _, err := io.ReadFull(rand.Reader, plain[8:12]); err != nil {
		return nil, err
	}
	binary.BigEndian.PutUint32(plain[12:], crc32.ChecksumIEEE(plain[:12]))
	blk, err := aes.NewCipher(vmessKDF16(cmdKey[:], "AES Auth ID Encryption"))
	if err != nil {
		return nil, err
	}
	var authID [16]byte
	blk.Encrypt(authID[:], plain[:])

	nonce := make([]byte, 8)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	lenAEAD, err := gcmOf(vmessKDF16(cmdKey[:], "VMess Header AEAD Key_Length", string(authID[:]), string(nonce)))
	if err != nil {
		return nil, err
	}
	lenNonce := vmessKDF(cmdKey[:], "VMess Header AEAD Nonce_Length", string(authID[:]), string(nonce))[:12]
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(header)))
	hdrAEAD, err := gcmOf(vmessKDF16(cmdKey[:], "VMess Header AEAD Key", string(authID[:]), string(nonce)))
	if err != nil {
		return nil, err
	}
	hdrNonce := vmessKDF(cmdKey[:], "VMess Header AEAD Nonce", string(authID[:]), string(nonce))[:12]

	out := make([]byte, 0, 16+18+8+len(header)+16)
	out = append(out, authID[:]...)
	out = lenAEAD.Seal(out, lenNonce, l[:], authID[:])
	out = append(out, nonce...)
	out = hdrAEAD.Seal(out, hdrNonce, header, authID[:])
	return out, nil
}

// vmessRequestHeader is the plaintext command section for a TCP connect.
func vmessRequestHeader(iv, key [16]byte, respHdr, sec byte, host string, port int) ([]byte, error) {
	var pad [1]byte
	if _, err := io.ReadFull(rand.Reader, pad[:]); err != nil {
		return nil, err
	}
	padLen := int(pad[0] & 0x0f)
	h := make([]byte, 0, 64+padLen)
	h = append(h, vmessVersion)
	h = append(h, iv[:]...)
	h = append(h, key[:]...)
	h = append(h, respHdr)
	h = append(h, vmessOptChunkStream|vmessOptChunkMasking|vmessOptPadding)
	h = append(h, byte(padLen<<4)|sec, 0x00, 0x01) // padding+security, reserved, TCP
	h = appendVAddr(h, host, port)
	if padLen > 0 {
		p := make([]byte, padLen)
		if _, err := io.ReadFull(rand.Reader, p); err != nil {
			return nil, err
		}
		h = append(h, p...)
	}
	f := fnv.New32a()
	f.Write(h)
	return f.Sum(h), nil
}

type vmessDialer struct {
	n       Node
	timeout time.Duration
}

func (d *vmessDialer) Close() {}

func (d *vmessDialer) DialContext(ctx context.Context, target string) (net.Conn, error) {
	host, port, err := splitTarget(target)
	if err != nil {
		return nil, err
	}
	id, err := parseUUID(d.n.Secret)
	if err != nil {
		return nil, err
	}
	sec, err := vmessSecurity(d.n.Cipher)
	if err != nil {
		return nil, err
	}
	var seed [33]byte
	if _, err := io.ReadFull(rand.Reader, seed[:]); err != nil {
		return nil, err
	}
	var iv, key [16]byte
	copy(iv[:], seed[:16])
	copy(key[:], seed[16:32])
	respHdr := seed[32]

	hdr, err := vmessRequestHeader(iv, key, respHdr, sec, host, port)
	if err != nil {
		return nil, err
	}
	sealed, err := sealVMessHeader(vmessCmdKey(id), hdr, time.Now())
	if err != nil {
		return nil, err
	}
	raw, err := dialTransport(ctx, d.n, d.timeout)
	if err != nil {
		return nil, err
	}
	vc, err := newVMessConn(raw, sec, iv, key, respHdr)
	if err != nil {
		raw.Close()
		return nil, err
	}
	if _, err := raw.Write(sealed); err != nil {
		raw.Close()
		return nil, err
	}
	return vc, nil
}

// vmessConn carries the chunked body in both directions.
type vmessConn struct {
	net.Conn
	respHdr byte
	respKey [16]byte
	respIV  [16]byte

	wmu    sync.Mutex
	wAEAD  cipher.AEAD
	wShake sha3.ShakeHash
	wIV    [16]byte
	wCount uint16
	wDone  bool

	rAEAD  cipher.AEAD
	rShake sha3.ShakeHash
	rIV    [16]byte
	rCount uint16
	rHead  bool
	rbuf   []byte
}

func vmessAEAD(sec byte, key []byte) (cipher.AEAD, error) {
	if sec == vmessSecChaCha {
		// 32-byte key: MD5 of the 16 bytes, then MD5 of that.
		var k [32]byte
		a := md5.Sum(key)
		copy(k[:16], a[:])
		b := md5.Sum(k[:16])
		copy(k[16:], b[:])
		return chacha20poly1305.New(k[:])
	}
	return gcmOf(key)
}

func shakeOf(iv []byte) sha3.ShakeHash {
	s := sha3.NewShake128()
	s.Write(iv)
	return s
}

func newVMessConn(raw net.Conn, sec byte, iv, key [16]byte, respHdr byte) (*vmessConn, error) {
	c := &vmessConn{Conn: raw, respHdr: respHdr}
	// The server derives the response keys from the request's.
	rk, ri := sha256.Sum256(key[:]), sha256.Sum256(iv[:])
	copy(c.respKey[:], rk[:16])
	copy(c.respIV[:], ri[:16])
	var err error
	if c.wAEAD, err = vmessAEAD(sec, key[:]); err != nil {
		return nil, err
	}
	if c.rAEAD, err = vmessAEAD(sec, c.respKey[:]); err != nil {
		return nil, err
	}
	c.wShake, c.rShake = shakeOf(iv[:]), shakeOf(c.respIV[:])
	c.wIV, c.rIV = iv, c.respIV
	return c, nil
}

// nextMask draws the next two bytes of the size mask stream.
func nextMask(s sha3.ShakeHash) uint16 {
	var b [2]byte
	_, _ = s.Read(b[:])
	return binary.BigEndian.Uint16(b[:])
}

func chunkNonce(iv [16]byte, count uint16) []byte {
	n := make([]byte, 12)
	copy(n, iv[:12])
	binary.BigEndian.PutUint16(n, count)
	return n
}

// appendChunk seals one chunk: masked size, ciphertext and tag, then padding.
// The padding length is drawn before the mask, for the reader and the writer
// alike.
func (c *vmessConn) appendChunk(out, plain []byte) ([]byte, error) {
	pad := int(nextMask(c.wShake) % 64)
	mask := nextMask(c.wShake)
	total := len(plain) + c.wAEAD.Overhead() + pad
	var sz [2]byte
	binary.BigEndian.PutUint16(sz[:], mask^uint16(total))
	out = append(out, sz[:]...)
	out = c.wAEAD.Seal(out, chunkNonce(c.wIV, c.wCount), plain, nil)
	c.wCount++
	if pad > 0 {
		p := make([]byte, pad)
		if _, err := io.ReadFull(rand.Reader, p); err != nil {
			return nil, err
		}
		out = append(out, p...)
	}
	return out, nil
}

func (c *vmessConn) Write(p []byte) (int, error) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.wDone {
		return 0, io.ErrClosedPipe
	}
	buf := make([]byte, 0, len(p)+len(p)/vmessChunk*100+100)
	for off := 0; off < len(p); {
		n := min(len(p)-off, vmessChunk)
		var err error
		if buf, err = c.appendChunk(buf, p[off:off+n]); err != nil {
			return 0, err
		}
		off += n
	}
	if _, err := c.Conn.Write(buf); err != nil {
		return 0, err
	}
	return len(p), nil
}

// Close ends the stream with the empty chunk the protocol uses for EOF, then
// closes the connection. The empty chunk is best effort: the connection is
// closed whether or not it got out.
func (c *vmessConn) Close() error {
	c.wmu.Lock()
	if !c.wDone {
		c.wDone = true
		if buf, err := c.appendChunk(nil, nil); err == nil {
			_ = c.Conn.SetWriteDeadline(time.Now().Add(time.Second))
			_, _ = c.Conn.Write(buf)
		}
	}
	c.wmu.Unlock()
	return c.Conn.Close()
}

var errVMessHandshake = errors.New("VMess 握手被服务器断开（常见原因：UUID 不对，或本机时间与服务器相差超过 2 分钟）")

// readHeader decrypts the response header and checks it answers this request.
func (c *vmessConn) readHeader() error {
	lenAEAD, err := gcmOf(vmessKDF16(c.respKey[:], "AEAD Resp Header Len Key"))
	if err != nil {
		return err
	}
	lenNonce := vmessKDF(c.respIV[:], "AEAD Resp Header Len IV")[:12]
	var enc [18]byte
	if _, err := io.ReadFull(c.Conn, enc[:]); err != nil {
		// A VMess server that does not accept the request closes the
		// connection without a word. Whatever way the close reaches us (end of
		// stream or a reset, worded differently on each system), nothing was
		// answered, and these are the two causes that happen.
		var ne net.Error
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || (errors.As(err, &ne) && !ne.Timeout()) {
			return errVMessHandshake
		}
		return err
	}
	lb, err := lenAEAD.Open(nil, lenNonce, enc[:], nil)
	if err != nil {
		return errors.New("VMess 响应头无法解密")
	}
	n := int(binary.BigEndian.Uint16(lb))
	hdrAEAD, err := gcmOf(vmessKDF16(c.respKey[:], "AEAD Resp Header Key"))
	if err != nil {
		return err
	}
	hdrNonce := vmessKDF(c.respIV[:], "AEAD Resp Header IV")[:12]
	body := make([]byte, n+16)
	if _, err := io.ReadFull(c.Conn, body); err != nil {
		return err
	}
	h, err := hdrAEAD.Open(nil, hdrNonce, body, nil)
	if err != nil || len(h) < 4 {
		return errors.New("VMess 响应头无法解密")
	}
	if h[0] != c.respHdr {
		return errors.New("VMess 响应不是对本次请求的回答")
	}
	return nil
}

func (c *vmessConn) Read(p []byte) (int, error) {
	if !c.rHead {
		if err := c.readHeader(); err != nil {
			return 0, err
		}
		c.rHead = true
	}
	for len(c.rbuf) == 0 {
		var sz [2]byte
		if _, err := io.ReadFull(c.Conn, sz[:]); err != nil {
			return 0, err
		}
		pad := int(nextMask(c.rShake) % 64)
		mask := nextMask(c.rShake)
		size := int(mask ^ binary.BigEndian.Uint16(sz[:]))
		if size == c.rAEAD.Overhead()+pad {
			return 0, io.EOF
		}
		if size < c.rAEAD.Overhead()+pad {
			return 0, errors.New("VMess 数据块长度无效")
		}
		body := make([]byte, size)
		if _, err := io.ReadFull(c.Conn, body); err != nil {
			return 0, err
		}
		plain, err := c.rAEAD.Open(nil, chunkNonce(c.rIV, c.rCount), body[:size-pad], nil)
		if err != nil {
			return 0, errors.New("VMess 数据块校验失败")
		}
		c.rCount++
		c.rbuf = plain
	}
	n := copy(p, c.rbuf)
	c.rbuf = c.rbuf[n:]
	return n, nil
}
