//go:build !windows

package wire

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"errors"
	"io"
	"os"
	"path/filepath"

	"aurora3/internal/statecrypt"
)

var sealedKeyHeader = []byte("AURORA-EXTERNAL-KEY\x01")

// Local options are a Windows-only durable product. Keep the generic entry
// config parsers usable on other systems without claiming local encryption.
func SealLocalOptions(data []byte) ([]byte, error) { return data, nil }
func OpenLocalOptions(data []byte) ([]byte, error) { return data, nil }

// Linux operators can provision a separate 32-byte key using systemd's
// LoadCredentialEncrypted. The path is a key source, not a key value.
func externalIdentityCipher() (cipher.AEAD, error) {
	dir := os.Getenv("CREDENTIALS_DIRECTORY")
	if dir == "" || !filepath.IsAbs(dir) {
		return nil, errors.New("缺少 systemd 独立凭据目录")
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	const name = "aurora-identity-key"
	fi, err := root.Lstat(name)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != 32 || fi.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("缺少或无法验证 32 字节私有凭据 aurora-identity-key")
	}
	f, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(fi, opened) {
		return nil, errors.New("凭据文件在打开时已变化")
	}
	secret, err := io.ReadAll(io.LimitReader(f, 33))
	defer clear(secret)
	if err != nil || len(secret) != 32 {
		return nil, errors.New("无法读取 Linux 身份加密凭据")
	}
	block, err := aes.NewCipher(secret)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithRandomNonce(block)
}

func sealIdentityKey(plain []byte) ([]byte, error) {
	if codec := statecrypt.Current(); codec != nil {
		return codec.Seal("tls-private-key", plain)
	}
	if os.Getenv("CREDENTIALS_DIRECTORY") == "" {
		// Legacy 3.x-compatible profile. Do not use this mode to claim
		// a compliant fully encrypted 4.0 deployment.
		return plain, nil
	}
	aead, err := externalIdentityCipher()
	if err != nil {
		return nil, err
	}
	return aead.Seal(bytes.Clone(sealedKeyHeader), nil, plain, sealedKeyHeader), nil
}

func unsealIdentityKey(stored []byte) ([]byte, error) {
	if codec := statecrypt.Current(); codec != nil || statecrypt.Protected(stored) {
		return codec.Open("tls-private-key", stored)
	}
	if bytes.HasPrefix(stored, sealedKeyHeader) {
		aead, err := externalIdentityCipher()
		if err != nil {
			return nil, err
		}
		return aead.Open(nil, nil, stored[len(sealedKeyHeader):], sealedKeyHeader)
	}
	if bytes.HasPrefix(stored, []byte("-----BEGIN ")) {
		return stored, nil
	}
	return nil, errors.New("无法识别已有身份密钥格式")
}
