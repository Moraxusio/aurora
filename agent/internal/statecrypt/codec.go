// Package statecrypt authenticates sensitive Aurora-managed records before
// they are parsed. Keys come from the OS or an operator's credential store.
package statecrypt

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"sync/atomic"
)

const KeyBytes = 32
const header = "AURORA-STATE\x01"
const Overhead = len(header) + 28 // AES-GCM with a 96-bit random nonce

type Codec struct {
	aead  cipher.AEAD
	idKey []byte
}

func New(key []byte) (*Codec, error) {
	if len(key) != KeyBytes {
		return nil, errors.New("invalid state key length")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCMWithRandomNonce(block)
	if err != nil {
		return nil, err
	}
	idKey, err := hkdf.Key(sha256.New, key, nil, "Aurora state object identifiers v1", KeyBytes)
	if err != nil {
		return nil, err
	}
	return &Codec{aead: aead, idKey: idKey}, nil
}

func Protected(data []byte) bool { return bytes.HasPrefix(data, []byte(header)) }

// ObjectID is a keyed content address. It enables deduplication inside an
// instance without exposing the unkeyed hashes of source files.
func (c *Codec) ObjectID(context string, data []byte) [sha256.Size]byte {
	h := hmac.New(sha256.New, c.idKey)
	h.Write([]byte(context))
	h.Write([]byte{0})
	h.Write(data)
	var id [sha256.Size]byte
	h.Sum(id[:0])
	return id
}

func (c *Codec) Seal(context string, plain []byte) ([]byte, error) {
	if c == nil || context == "" {
		return nil, errors.New("state protection requires a key and record context")
	}
	return c.aead.Seal([]byte(header), nil, plain, []byte(header+"\x00"+context)), nil
}

func (c *Codec) Open(context string, ciphertext []byte) ([]byte, error) {
	if c == nil || context == "" || !Protected(ciphertext) {
		return nil, errors.New("state record requires an authenticated envelope and key")
	}
	return c.aead.Open(nil, nil, ciphertext[len(header):], []byte(header+"\x00"+context))
}

var process atomic.Pointer[Codec]

// Activate is called once by the owning agent, before startup recovery.
// A process is never allowed to switch keys while other services are running.
func Activate(codec *Codec) error {
	if codec == nil || !process.CompareAndSwap(nil, codec) {
		return errors.New("state protection is unavailable or already activated")
	}
	return nil
}

func Current() *Codec { return process.Load() }
