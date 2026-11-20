package entry

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// PrepareLocalProtection must run under the state writer lock. It never
// generates a key for a non-empty unprotected directory or a lost key.
func PrepareLocalProtection(dir string) (*statecrypt.Codec, error) {
	root, err := statecrypt.OpenStateDir(dir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	existing, err := statecrypt.ReadRegular(root, statecrypt.KeyFile, 64<<10)
	if err == nil {
		marker, err := statecrypt.ReadRegular(root, statecrypt.ProtectedMarker, 128)
		if err != nil || string(marker) != statecrypt.MarkerValue {
			return nil, errors.New("受保护状态缺少完整初始化标记")
		}
		_, _, id, err := readIdentity(dir)
		if err != nil {
			return nil, fmt.Errorf("受保护状态缺少可验证身份：%w", err)
		}
		if err := wire.RequireProtectedIdentity(dir, "agent"); err != nil {
			return nil, err
		}
		return statecrypt.UnwrapKeyFor(existing, id)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := statecrypt.CheckNewDir(dir); err != nil {
		return nil, err
	}
	// Initialize the identity before publishing the key. If interrupted
	// between writes, no service has listened and a subsequent start
	// refuses the incomplete state instead of inventing a replacement.
	_, _, id, err := loadIdentity(dir)
	if err != nil {
		return nil, err
	}
	return newLocalStateKey(dir, id)
}

func newLocalStateKey(dir, id string) (*statecrypt.Codec, error) {
	var key [statecrypt.KeyBytes]byte
	defer clear(key[:])
	if _, err := rand.Read(key[:]); err != nil {
		return nil, err
	}
	envelope, err := statecrypt.WrapKeyFor(key[:], id)
	if err != nil {
		return nil, err
	}
	if err := wire.WriteNewIdentityFile(filepath.Join(dir, statecrypt.KeyFile), envelope, 0o600); err != nil {
		return nil, err
	}
	if err := wire.WriteNewIdentityFile(filepath.Join(dir, statecrypt.ProtectedMarker), []byte(statecrypt.MarkerValue), 0o600); err != nil {
		return nil, err
	}
	return statecrypt.New(key[:])
}

func CloneLocalIdentity(source, stage string) (*statecrypt.Codec, string, error) {
	id, pin, err := cloneIdentity(source, stage, wire.ProtectIdentityKey)
	if err != nil {
		return nil, "", err
	}
	options, err := LoadLocalOptions(filepath.Join(source, "local-agent.json"))
	if err == nil {
		cfg := Config{Kind: "local", Services: options.Services, Proxy: options.Proxy}
		if err := cfg.Save(filepath.Join(stage, "local-agent.json")); err != nil {
			return nil, "", err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, "", err
	}
	codec, err := newLocalStateKey(stage, id)
	return codec, pin, err
}
