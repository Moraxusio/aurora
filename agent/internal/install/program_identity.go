//go:build linux

package install

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/entry"
	"aurora3/internal/statecrypt"
)

type programIdentity struct {
	id, pin        string
	cfg, unit      [sha256.Size]byte
	cert, key, tag [sha256.Size]byte
}

func regularRecord(path string, max int64) ([]byte, error) {
	r, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return statecrypt.ReadRegular(r, filepath.Base(path), max)
}

func (e *Env) captureProgramIdentity(c *entry.Config) (*programIdentity, error) {
	dir := e.p(c.StateDir)
	var o programIdentity
	for _, item := range []struct {
		path string
		max  int64
		sum  *[sha256.Size]byte
	}{
		{e.p(e.lay().ConfigPath), 8 << 20, &o.cfg}, {e.p(e.lay().UnitPath), 1 << 20, &o.unit},
		{filepath.Join(dir, "agent.crt"), 64 << 10, &o.cert}, {filepath.Join(dir, "agent.key"), 64 << 10, &o.key},
		{filepath.Join(dir, "agent-id"), 128, &o.tag},
	} {
		b, err := regularRecord(item.path, item.max)
		if err != nil {
			return nil, err
		}
		*item.sum = sha256.Sum256(b)
		if item.sum == &o.tag {
			o.id = strings.TrimSpace(string(b))
		}
		clear(b)
	}
	if _, err := hex.DecodeString(o.id); err != nil || len(o.id) != 24 {
		return nil, errors.New("现有 agent ID 无效")
	}
	pin, err := readPin(filepath.Join(dir, "agent.crt"))
	if err != nil {
		return nil, err
	}
	o.pin = pin
	return &o, nil
}

func (e *Env) checkProgramIdentity(s *staged) error {
	if s.identity == nil {
		return nil
	}
	copy, err := e.captureProgramIdentity(s.conf)
	if err != nil || *copy != *s.identity {
		return errors.New("配置、单元或配对身份在切换期间已变化；不会用默认设置覆盖")
	}
	return nil
}
