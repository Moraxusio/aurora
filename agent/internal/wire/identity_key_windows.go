package wire

import (
	"bytes"
	"errors"
	"path/filepath"

	"aurora3/internal/statecrypt"
)

var dpapiKeyHeader = []byte("AURORA-DPAPI-KEY\x01")
var dpapiStateHeader = []byte("AURORA-DPAPI-STATE\x01")

func RequireProtectedIdentity(dir, name string) error {
	root, err := statecrypt.OpenStateDir(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	b, err := statecrypt.ReadRegular(root, filepath.Base(name)+".key", 64<<10)
	if err != nil {
		return err
	}
	defer clear(b)
	if !bytes.HasPrefix(b, dpapiKeyHeader) {
		return errors.New("受保护状态不允许使用旧明文身份密钥")
	}
	return nil
}

func sealIdentityKey(plain []byte) ([]byte, error) {
	b, err := dpapi(plain, dpapiKeyHeader, true)
	if err != nil {
		return nil, err
	}
	return append(bytes.Clone(dpapiKeyHeader), b...), nil
}

func ProtectIdentityKey(plain []byte) ([]byte, error) { return sealIdentityKey(plain) }

func unsealIdentityKey(stored []byte) ([]byte, error) {
	if bytes.HasPrefix(stored, dpapiKeyHeader) {
		return dpapi(stored[len(dpapiKeyHeader):], dpapiKeyHeader, false)
	}
	// Reading an existing 3.x PEM is compatibility, not silently writing a
	// new plaintext key. Legacy migration is a separate verified operation.
	if bytes.HasPrefix(stored, []byte("-----BEGIN ")) {
		return stored, nil
	}
	return nil, errors.New("无法识别已有身份密钥格式")
}

// SealLocalOptions protects local service choices and proxy credentials at rest.
func SealLocalOptions(plain []byte) ([]byte, error) {
	b, err := dpapi(plain, dpapiStateHeader, true)
	if err != nil {
		return nil, err
	}
	return append(bytes.Clone(dpapiStateHeader), b...), nil
}

func OpenLocalOptions(stored []byte) ([]byte, error) {
	if bytes.HasPrefix(stored, dpapiStateHeader) {
		return dpapi(stored[len(dpapiStateHeader):], dpapiStateHeader, false)
	}
	if statecrypt.Current() == nil && bytes.HasPrefix(bytes.TrimSpace(stored), []byte("{")) {
		return stored, nil // legacy, not a write fallback
	}
	return nil, errors.New("无法识别本地 agent 配置格式")
}

func dpapi(data, entropy []byte, seal bool) ([]byte, error) {
	if bytes.Equal(entropy, dpapiKeyHeader) {
		entropy = []byte("Aurora Windows local agent identity v1")
	}
	return statecrypt.UserDPAPI(data, entropy, seal)
}
