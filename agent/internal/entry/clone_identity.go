//go:build linux || windows

package entry

import (
	"crypto/x509"
	"encoding/pem"
	"path/filepath"

	"aurora3/internal/wire"
)

func cloneIdentity(source, stage string, protect func([]byte) ([]byte, error)) (id, pin string, err error) {
	cert, pin, id, err := readIdentity(source)
	if err != nil {
		return "", "", err
	}
	der, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		return "", "", err
	}
	defer clear(der)
	plain := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	defer clear(plain)
	stored, err := protect(plain)
	if err != nil {
		return "", "", err
	}
	pub := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
	for name, record := range map[string][]byte{
		"agent-id":  []byte(id + "\n"),
		"agent.key": stored,
		"agent.crt": pub,
	} {
		if err := wire.WriteNewIdentityFile(filepath.Join(stage, name), record, 0o600); err != nil {
			return "", "", err
		}
	}
	return id, pin, nil
}
