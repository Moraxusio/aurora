// Package entry is the agent's entry point (D-8): identity, the direct TLS
// listener, Hello, the yamux session and dispatch to the services. The
// listener and Hello follow v2 internal/agent/server.go; names, paths and the
// port are v3's own, so v3 runs beside v2 on one machine (D-71).
package entry

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// v3 names (D-71). None of them is a prefix of a v2 name or the other way round.
const (
	DefaultConfigPath = "/etc/aurora3/agent.json"
	DefaultStateDir   = "/var/lib/aurora3"
	DefaultListen     = ":17710" // D-76: 7710 is taken by v2 on the WSL test machine
)

// Config lives in /etc/aurora3/agent.json. It holds the direct token, so it is
// written with 0600 permissions.
type Config struct {
	Kind string `json:"kind,omitempty"` // local lifecycle is independent of GOOS
	// Instance names this agent when several run on one server (D-101); empty
	// is the default instance. It decides the tmux socket and unit names.
	Instance string `json:"instance,omitempty"`
	Name     string `json:"name"`
	Listen   string `json:"listen"`          // direct TLS listener, default ":17710"
	Token    string `json:"token,omitempty"` // direct client token (legacy JSON only)
	// PublicAddrs are extra host:port values clients should try (NAT, port
	// forward). Local interface addresses are added at run time.
	PublicAddrs []string `json:"public_addrs,omitempty"`
	StateDir    string   `json:"state_dir"`

	Roots          []Root              `json:"roots"`
	Services       map[string]bool     `json:"services,omitempty"` // D-41: missing means on
	ServiceActions map[string][]string `json:"service_actions,omitempty"`
	UploadMaxBytes int64               `json:"upload_max_bytes,omitempty"`
	AuditLog       string              `json:"audit_log,omitempty"`

	// Proxy is the proxy service's state (the chosen node and the local
	// listener's credentials). The entry keeps it as it is and does not look
	// inside: it holds a password, so the file is 0600 like the token (D-90).
	Proxy json.RawMessage `json:"proxy,omitempty"`

	protection *statecrypt.Codec // non-nil for an authenticated remote config
}

// Root is a top-level folder clients may work in.
type Root struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
}

func LoadConfig(path string) (*Config, error) {
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer root.Close()
	b, err := statecrypt.ReadRegular(root, filepath.Base(path), 8<<20)
	if err != nil {
		return nil, err
	}
	defer clear(b)
	var stored struct {
		Sealed string `json:"protected_config"`
	}
	if err := json.Unmarshal(b, &stored); err != nil {
		return nil, fmt.Errorf("配置文件格式错误：%w", err)
	}
	if stored.Sealed != "" {
		return openProtectedConfig(path, b)
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("配置文件格式错误：%w", err)
	}
	return &c, c.Validate()
}

func (c *Config) Protection() *statecrypt.Codec { return c.protection }

type LocalOptions struct {
	Services map[string]bool `json:"services,omitempty"`
	Proxy    json.RawMessage `json:"proxy,omitempty"`
}

func LoadLocalOptions(path string) (LocalOptions, error) {
	var out LocalOptions
	fi, err := os.Lstat(path)
	if err != nil {
		return out, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > 4<<20 {
		return out, errors.New("本地 agent 配置不是可读取的普通文件")
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		return out, err
	}
	defer clear(stored)
	plain, err := wire.OpenLocalOptions(stored)
	if err != nil {
		return out, err
	}
	defer clear(plain)
	if err := json.Unmarshal(plain, &out); err != nil {
		return LocalOptions{}, err
	}
	return out, nil
}

// Validate checks the config and fills the defaults. The rules and messages
// are v2's (internal/agent/config.go).
func (c *Config) Validate() error {
	if c.Kind != "" && c.Kind != "remote" && c.Kind != "local" {
		return errors.New("未知的 agent 类型")
	}
	if c.Kind == "local" {
		host, _, err := net.SplitHostPort(c.Listen)
		if err != nil || host != "127.0.0.1" {
			return errors.New("本地 agent 只能监听 IPv4 回环地址")
		}
	}
	if len(c.Token) < 32 {
		return errors.New("token 至少 32 个字符")
	}
	if c.Listen == "" {
		c.Listen = DefaultListen
	}
	if err := ValidInstance(c.Instance); err != nil {
		return err
	}
	if c.StateDir == "" {
		l, _ := LayoutFor(c.Instance)
		c.StateDir = l.StateDir
	}
	if c.UploadMaxBytes <= 0 {
		c.UploadMaxBytes = 64 << 30
	}
	if len(c.Roots) == 0 {
		return errors.New("至少需要一个文件根目录")
	}
	seen := map[string]bool{}
	for i := range c.Roots {
		r := &c.Roots[i]
		if r.ID == "" || strings.ContainsAny(r.ID, "/\\") || seen[r.ID] {
			return fmt.Errorf("根目录 id 无效或重复：%q", r.ID)
		}
		seen[r.ID] = true
		if !filepath.IsAbs(r.Path) {
			return fmt.Errorf("根目录必须是绝对路径：%q", r.Path)
		}
		r.Path = filepath.Clean(r.Path)
		if r.Label == "" {
			r.Label = r.ID
		}
	}
	return nil
}

// Save writes the config atomically with 0600 permissions (it holds secrets).
func (c *Config) Save(path string) error {
	if c.protection != nil {
		stored, err := encodeProtectedConfig(path, c)
		if err != nil {
			return err
		}
		return saveConfigBytes(path, stored)
	}
	var saved any = c
	if c.Kind == "local" {
		// Local bootstrap identity is ephemeral. Persist only service choices;
		// never write the per-launch direct token or restore a stale bind/root.
		saved = LocalOptions{c.Services, c.Proxy}
	}
	b, err := json.MarshalIndent(saved, "", "  ")
	if err != nil {
		return err
	}
	defer clear(b)
	stored := append(b, '\n')
	if c.Kind == "local" {
		stored, err = wire.SealLocalOptions(stored)
		if err != nil {
			return fmt.Errorf("无法保护本地 agent 配置：%w", err)
		}
	}
	return saveConfigBytes(path, stored)
}

func saveConfigBytes(path string, stored []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".aurora-config-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(stored)
	if err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return statecrypt.ReplaceFile(tmp.Name(), path)
}
