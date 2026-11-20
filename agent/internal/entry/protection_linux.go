package entry

import (
	"bytes"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// ValidatePreviewPairing reads only public identity data for an isolated
// pinned TLS probe; the starting agent validates the corresponding key.
func ValidatePreviewPairing(dir *os.Root) (pin, id string, err error) {
	crt, err := statecrypt.ReadRegular(dir, "agent.crt", 64<<10)
	if err != nil {
		return "", "", err
	}
	block, _ := pem.Decode(crt)
	if block == nil || block.Type != "CERTIFICATE" {
		return "", "", errors.New("旧配对证书无效")
	}
	tag, err := statecrypt.ReadRegular(dir, "agent-id", 128)
	if err != nil {
		return "", "", err
	}
	id = strings.TrimSpace(string(tag))
	if _, err := hex.DecodeString(id); err != nil || len(id) != 24 {
		return "", "", errors.New("旧配对 ID 无效")
	}
	return wire.CertPin(block.Bytes), id, nil
}

// PrepareProtectedLinuxState runs under the writer lock after the config has
// authenticated. It will never attach a fresh key to existing mutable state.
func PrepareProtectedLinuxState(c *Config) error {
	if c.protection == nil || c.Kind == "local" {
		return errors.New("未提供受保护的 Linux 配置")
	}
	root, err := statecrypt.OpenStateDir(c.StateDir)
	if err != nil {
		return err
	}
	defer root.Close()
	marker, err := statecrypt.ReadRegular(root, statecrypt.ProtectedMarker, 128)
	if err != nil || string(marker) != statecrypt.MarkerValue {
		return errors.New("受保护状态缺少完整初始化标记")
	}
	// Open through a regular file and authenticate before any listener.
	record, err := statecrypt.ReadRegular(root, statecrypt.KeyFile, 4096)
	if err != nil {
		return err
	}
	id, err := c.protection.Open("linux-state-owner:"+c.Instance, record)
	if err != nil {
		return err
	}
	agentID, err := statecrypt.ReadRegular(root, "agent-id", 128)
	if err != nil || !bytes.Equal(bytes.TrimSpace(agentID), id) {
		return errors.New("受保护状态与原 agent 身份不一致")
	}
	if _, _, _, err := readIdentity(c.StateDir); err != nil {
		return err
	}
	return nil
}

func writeLinuxOwner(dir, instance, id string, codec *statecrypt.Codec) error {
	b, err := codec.Seal("linux-state-owner:"+instance, []byte(id))
	if err != nil {
		return err
	}
	if err := wire.WriteNewIdentityFile(filepath.Join(dir, statecrypt.KeyFile), b, 0o600); err != nil {
		return err
	}
	return wire.WriteNewIdentityFile(filepath.Join(dir, statecrypt.ProtectedMarker), []byte(statecrypt.MarkerValue), 0o600)
}

// CloneLinuxIdentity stages a preview config with an ephemeral loopback
// listener and an independent instance. Nothing is installed or restarted.
func IsolatedCloneRoots(roots []Root, final string) []Root {
	out := append([]Root(nil), roots...)
	for i := range out {
		out[i].Path = filepath.Join(final, "fixture-projects", fmt.Sprint(i))
	}
	return out
}

// InitializeLinuxPreview creates an identity and encrypted configuration for
// a new isolated workspace. It never opens an existing state as new.
func InitializeLinuxPreview(final, instance, token string) error {
	if instance == "" || len(token) != 64 {
		return errors.New("必须提供具名实例和 32 字节随机配对令牌（十六进制）")
	}
	if _, err := hex.DecodeString(token); err != nil {
		return errors.New("配对令牌必须是十六进制")
	}
	codec, err := statecrypt.Credential()
	if err != nil {
		return err
	}
	cfg := &Config{
		Instance: instance, Name: "Aurora 4 Preview", StateDir: final,
		Listen: "127.0.0.1:0", Token: token, protection: codec,
		Roots: IsolatedCloneRoots([]Root{{ID: "workspace", Label: "Preview workspace"}}, final),
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	return statecrypt.StageNewDirectory(final, func(stage string) error {
		record, err := encodeProtectedConfig(filepath.Join(final, "agent.json"), cfg)
		if err != nil {
			return err
		}
		if err := statecrypt.Activate(codec); err != nil {
			return err
		}
		_, _, id, err := loadIdentity(stage)
		if err != nil {
			return err
		}
		if err := writeLinuxOwner(stage, instance, id, codec); err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Join(stage, "fixture-projects", "0"), 0o700); err != nil {
			return err
		}
		return wire.WriteNewIdentityFile(filepath.Join(stage, "agent.json"), record, 0o600)
	})
}

func CloneLinuxIdentity(source *Config, stage, final, instance string) (*statecrypt.Codec, string, error) {
	if source.Protection() != nil || source.Kind == "local" || instance == "" || instance == source.Instance {
		return nil, "", errors.New("只支持旧配置克隆，且必须指定新的具名验收实例")
	}
	codec, err := statecrypt.Credential()
	if err != nil {
		return nil, "", err
	}
	config := *source
	config.protection = codec
	config.Listen = net.JoinHostPort("127.0.0.1", "0")
	config.PublicAddrs, config.AuditLog = nil, ""
	config.Instance, config.StateDir = instance, final
	config.ServiceActions = nil
	config.Roots = IsolatedCloneRoots(source.Roots, final)
	for _, root := range config.Roots {
		relative, err := filepath.Rel(final, root.Path)
		if err != nil {
			return nil, "", err
		}
		if err := os.MkdirAll(filepath.Join(stage, relative), 0o700); err != nil {
			return nil, "", err
		}
	}
	config.Services = map[string]bool{}
	for name, enabled := range source.Services {
		config.Services[name] = enabled
	}
	// Do not connect the copy to external networks or the host's systemd.
	for _, service := range []string{"proxy", "net", "systemd", "terminal"} {
		delete(config.Services, service)
	}
	if err := config.Validate(); err != nil {
		return nil, "", err
	}
	id, pin, err := cloneIdentity(source.StateDir, stage, func(plain []byte) ([]byte, error) {
		return codec.Seal("tls-private-key", plain)
	})
	if err != nil {
		return nil, "", err
	}
	if err := writeLinuxOwner(stage, instance, id, codec); err != nil {
		return nil, "", err
	}
	record, err := encodeProtectedConfig(filepath.Join(final, "agent.json"), &config)
	if err != nil {
		return nil, "", err
	}
	if err := wire.WriteNewIdentityFile(filepath.Join(stage, "agent.json"), record, 0o600); err != nil {
		return nil, "", err
	}
	return codec, pin, nil
}
