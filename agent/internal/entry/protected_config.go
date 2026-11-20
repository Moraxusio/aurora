//go:build linux || windows

package entry

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"aurora3/internal/statecrypt"
)

type protectedConfig struct {
	Config
	Sealed string `json:"protected_config"`
}

type configSecrets struct {
	Token string          `json:"token"`
	Proxy json.RawMessage `json:"proxy,omitempty"`
}

func configContext(path string, c *Config) (string, error) {
	public := *c
	public.Token, public.Proxy = "", nil
	b, err := json.Marshal(public)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return "remote-config:v1:" + filepath.Clean(path) + "\x00" + hex.EncodeToString(sum[:]), nil
}

func openProtectedConfig(path string, raw []byte) (*Config, error) {
	var p protectedConfig
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	if p.Kind == "local" || p.Token != "" || len(p.Proxy) != 0 || !filepath.IsAbs(p.StateDir) || !filepath.IsAbs(path) {
		return nil, errors.New("受保护配置不能同时使用明文凭据，且路径必须为绝对路径")
	}
	codec, err := statecrypt.Credential()
	if err != nil {
		return nil, err
	}
	sealed, err := base64.StdEncoding.Strict().DecodeString(p.Sealed)
	if err != nil {
		return nil, err
	}
	context, err := configContext(path, &p.Config)
	if err != nil {
		return nil, err
	}
	plain, err := codec.Open(context, sealed)
	if err != nil {
		return nil, fmt.Errorf("无法验证受保护配置（原件未改动）：%w", err)
	}
	defer clear(plain)
	var secrets configSecrets
	if err := json.Unmarshal(plain, &secrets); err != nil {
		return nil, err
	}
	p.Token, p.Proxy, p.protection = secrets.Token, secrets.Proxy, codec
	return &p.Config, p.Config.Validate()
}

func encodeProtectedConfig(path string, c *Config) ([]byte, error) {
	if c.protection == nil || c.Kind == "local" || !filepath.IsAbs(c.StateDir) || !filepath.IsAbs(path) {
		return nil, errors.New("无法建立受保护配置")
	}
	var p protectedConfig
	p.Config = *c
	p.Token, p.Proxy = "", nil
	plain, err := json.Marshal(configSecrets{Token: c.Token, Proxy: c.Proxy})
	if err != nil {
		return nil, err
	}
	defer clear(plain)
	context, err := configContext(path, c)
	if err != nil {
		return nil, err
	}
	sealed, err := c.protection.Seal(context, plain)
	if err != nil {
		return nil, err
	}
	p.Sealed = base64.StdEncoding.EncodeToString(sealed)
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(b) > (8<<20)-1 {
		return nil, errors.New("受保护配置超出大小限制")
	}
	return append(b, '\n'), nil
}
