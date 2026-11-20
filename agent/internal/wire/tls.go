package wire

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// CertPin is the hex SHA-256 of a certificate's DER encoding.
func CertPin(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

// LoadOrCreateCert keeps a self-signed ECDSA certificate in dir and returns it
// with its pin. Clients trust it by pin, so no CA or hostname is involved.
func LoadOrCreateCert(dir, name string) (tls.Certificate, string, error) {
	certPath, keyPath := filepath.Join(dir, name+".crt"), filepath.Join(dir, name+".key")
	cert, pin, err := LoadCert(dir, name)
	if !errors.Is(err, os.ErrNotExist) {
		return cert, pin, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "aurora-" + name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(30, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	defer clear(keyDER)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	defer clear(keyPEM)
	stored, err := sealIdentityKey(keyPEM)
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("无法保护 TLS 身份密钥：%w", err)
	}
	defer clear(stored)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := WriteNewIdentityFile(keyPath, stored, 0o600); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := WriteNewIdentityFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return tls.Certificate{}, "", err
	}
	return LoadCert(dir, name)
}

// LoadCert returns os.ErrNotExist only when neither identity file exists.
// A partial pair, unreadable files, symlinks or a bad key are never a request
// to generate a replacement identity.
func LoadCert(dir, name string) (tls.Certificate, string, error) {
	crt, key := filepath.Join(dir, name+".crt"), filepath.Join(dir, name+".key")
	c, ce := os.Lstat(crt)
	k, ke := os.Lstat(key)
	if errors.Is(ce, os.ErrNotExist) && errors.Is(ke, os.ErrNotExist) {
		return tls.Certificate{}, "", os.ErrNotExist
	}
	if ce != nil || ke != nil || !c.Mode().IsRegular() || !k.Mode().IsRegular() ||
		c.Size() > 64<<10 || k.Size() > 64<<10 {
		return tls.Certificate{}, "", errors.New("TLS 身份文件不完整或无法读取；已保留原件")
	}
	certPEM, err := os.ReadFile(crt)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	keyStored, err := os.ReadFile(key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	defer clear(keyStored)
	keyPEM, err := unsealIdentityKey(keyStored)
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("无法解读 TLS 身份密钥；已保留原件：%w", err)
	}
	defer clear(keyPEM)
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("TLS 身份无法验证；已保留原件：%w", err)
	}
	return cert, CertPin(cert.Certificate[0]), nil
}

// Exclusive creation also protects against overlapping first starts. A
// partial write is deliberately preserved and blocks future initialization.
func WriteNewIdentityFile(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	return err
}

func ServerTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13}
}

var ErrPinMismatch = errors.New("证书指纹不匹配")

// PinnedTLS verifies the peer by certificate pin instead of a CA chain.
func PinnedTLS(pin string) *tls.Config {
	want := strings.ToLower(strings.TrimSpace(pin))
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, // replaced by VerifyConnection below
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return ErrPinMismatch
			}
			got := CertPin(cs.PeerCertificates[0].Raw)
			if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
				return ErrPinMismatch
			}
			return nil
		},
	}
}

// TokenEqual compares secrets in constant time.
func TokenEqual(a, b string) bool {
	return a != "" && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// NewToken returns a random 256-bit hex secret.
func NewToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
