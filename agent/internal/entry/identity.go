package entry

import (
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// readIdentity never writes; migration and protected startup may validate a
// complete existing identity without authorizing first-time initialization.
func readIdentity(dir string) (tls.Certificate, string, string, error) {
	root, err := statecrypt.OpenStateDir(dir)
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	defer root.Close()
	b, idErr := statecrypt.ReadRegular(root, "agent-id", 128)
	cert, pin, certErr := wire.LoadCert(dir, "agent")
	if idErr == nil {
		if certErr != nil {
			return tls.Certificate{}, "", "", errors.New("已有 agent 身份不完整，未重置；请恢复原证书和身份文件")
		}
		id := strings.TrimSpace(string(b))
		_, hexErr := hex.DecodeString(id)
		if hexErr != nil || len(id) != 24 {
			return tls.Certificate{}, "", "", errors.New("已有 agent-id 无法读取或格式无效，未重置")
		}
		return cert, pin, id, nil
	}
	if !errors.Is(idErr, os.ErrNotExist) || !errors.Is(certErr, os.ErrNotExist) {
		return tls.Certificate{}, "", "", errors.New("已有 agent 身份不完整或无法读取，未重置")
	}
	return tls.Certificate{}, "", "", os.ErrNotExist
}

func loadIdentity(dir string) (tls.Certificate, string, string, error) {
	cert, pin, id, err := readIdentity(dir)
	if !errors.Is(err, os.ErrNotExist) {
		return cert, pin, id, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return tls.Certificate{}, "", "", err
	}
	for _, ent := range entries {
		switch ent.Name() {
		case "file-transactions":
			// An empty journal folder alone does not identify an instance.
			contents, err := os.ReadDir(filepath.Join(dir, ent.Name()))
			if err == nil && len(contents) == 0 {
				continue
			}
		case statecrypt.WriterFile:
			if ent.Type().IsRegular() {
				continue
			}
		default:
			// Initial Linux installation has private installer staging and
			// may retain the first-install rollback preimage until ready.
			if ent.IsDir() && (strings.HasPrefix(ent.Name(), "install-") || strings.HasPrefix(ent.Name(), "rollback-")) {
				continue
			}
		}
		return tls.Certificate{}, "", "", fmt.Errorf("目录已有 agent 状态（%s），但缺少身份；未自动重置", ent.Name())
	}
	id = wire.NewToken()[:24]
	// Reserve a fresh identity before creating the pair. If interrupted,
	// the next invocation fails closed and preserves forensic evidence.
	if err := wire.WriteNewIdentityFile(filepath.Join(dir, "agent-id"), []byte(id+"\n"), 0o600); err != nil {
		return tls.Certificate{}, "", "", err
	}
	cert, pin, err = wire.LoadOrCreateCert(dir, "agent")
	return cert, pin, id, err
}
