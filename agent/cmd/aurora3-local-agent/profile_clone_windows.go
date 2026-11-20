package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

const clientDPAPIPurpose = "aurora3-profile-v1"
const profileDPAPIHeader = "AURORA3P\x01\x05dpapi"

var clientRecord = regexp.MustCompile(`^[a-f0-9]{64}\.(?:doc|dev)$`)

// cloneClientPreview copies recognized, authenticated ciphertext verbatim.
// No JSON round trip can silently drop settings unknown to this build.
func cloneClientPreview(args []string) error {
	f := flag.NewFlagSet("clone-client-preview", flag.ContinueOnError)
	source := f.String("source", "", "已停止的 Windows 客户端配置目录")
	dest := f.String("dest", "", "空白且尚不存在的验收目录")
	stopped := f.Bool("source-stopped", false, "确认该配置的所有旧客户端和 agent 已退出")
	if err := f.Parse(args); err != nil {
		return err
	}
	if !*stopped || *source == "" || *dest == "" || f.NArg() != 0 {
		return errors.New("必须提供旧客户端配置目录、验收目录和 --source-stopped")
	}
	return statecrypt.CloneDirectory(*source, *dest, func(stage string, names []string) error {
		root, err := statecrypt.OpenStateDir(*source)
		if err != nil {
			return err
		}
		defer root.Close()
		budget := int64(512 << 20)
		foundProfile := false
		for _, name := range names {
			switch name {
			case "profile.bin", "profile.bin.before-local-v1":
				b, err := statecrypt.ReadRegular(root, name, 64<<20)
				if err != nil {
					return err
				}
				if !bytes.HasPrefix(b, []byte(profileDPAPIHeader)) {
					return errors.New("旧 Profile 没有受支持的 DPAPI 格式")
				}
				if err := checkClientDPAPI(b[len(profileDPAPIHeader):], ""); err != nil {
					return err
				}
				if err := wire.WriteNewIdentityFile(filepath.Join(stage, name), b, 0o600); err != nil {
					return err
				}
				foundProfile = foundProfile || name == "profile.bin"
				budget -= int64(len(b))
			case "documents", "development":
				if err := cloneClientRecords(filepath.Join(*source, name), filepath.Join(stage, name), name, &budget); err != nil {
					return err
				}
			case "local-agent":
				if _, err := cloneLocalState(filepath.Join(*source, name), filepath.Join(stage, name), filepath.Join(*dest, name)); err != nil {
					return err
				}
			default:
				return errors.New("客户端包含未知或待恢复的状态；保留旧配置，不发布不完整克隆")
			}
		}
		if !foundProfile || budget < 0 {
			return errors.New("客户端 Profile 不完整或超过克隆预算")
		}
		return nil
	})
}

func checkClientDPAPI(b []byte, name string) error {
	cleartext, err := statecrypt.UserDPAPI(b, []byte(clientDPAPIPurpose), false)
	if err != nil {
		return errors.New("旧客户端数据不能由当前 Windows 用户解开")
	}
	defer clear(cleartext)
	trimmed := bytes.TrimSpace(cleartext)
	if !bytes.HasPrefix(trimmed, []byte("{")) || !json.Valid(trimmed) {
		return errors.New("旧客户端加密数据结构无效")
	}
	if name != "" {
		kind := filepath.Ext(name)
		var header struct {
			Format  int    `json:"format"`
			Version int    `json:"version"`
			Server  string `json:"server"`
			Key     struct {
				Server string `json:"server"`
				Root   string `json:"root"`
				Path   string `json:"path"`
			} `json:"key"`
		}
		if err := json.Unmarshal(trimmed, &header); err != nil ||
			(kind == ".doc" && (header.Format != 1 || header.Key.Server == "" || header.Key.Root == "" || header.Key.Path == "")) ||
			(kind == ".dev" && (header.Version != 1 || header.Server == "")) {
			return errors.New("旧客户端记录不是受支持的恢复格式")
		}
		var identity []byte
		if kind == ".dev" {
			identity = []byte(header.Server)
		} else {
			var target bytes.Buffer
			enc := json.NewEncoder(&target)
			enc.SetEscapeHTML(false)
			if err := enc.Encode([3]string{header.Key.Server, header.Key.Root, header.Key.Path}); err != nil {
				return err
			}
			identity = bytes.TrimSuffix(target.Bytes(), []byte{'\n'})
			cleartext := identity
			defer clear(cleartext)
		}
		id := sha256.Sum256(identity)
		if name != hex.EncodeToString(id[:])+kind {
			return errors.New("旧客户端恢复记录与文件身份不一致")
		}
	}
	return nil
}

func cloneClientRecords(src, dst, kind string, budget *int64) error {
	root, err := statecrypt.OpenStateDir(src)
	if err != nil {
		return err
	}
	defer root.Close()
	records, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		return err
	}
	if len(records) > 20000 {
		return errors.New("客户端记录数量超出迁移预算")
	}
	ext, limit := ".doc", int64(40<<20)
	if kind == "development" {
		ext, limit = ".dev", 16<<20
	}
	if err := os.Mkdir(dst, 0o700); err != nil {
		return err
	}
	for _, record := range records {
		if !record.Type().IsRegular() || !clientRecord.MatchString(record.Name()) || filepath.Ext(record.Name()) != ext {
			return errors.New("存在未知、临时或未完成的客户端恢复记录")
		}
		b, err := statecrypt.ReadRegular(root, record.Name(), limit)
		if err != nil {
			return err
		}
		*budget -= int64(len(b))
		if *budget < 0 {
			return errors.New("客户端记录超出克隆预算")
		}
		if err := checkClientDPAPI(b, record.Name()); err != nil {
			return fmt.Errorf("无法验证客户端 %s 恢复记录：%w", kind, err)
		}
		if err := wire.WriteNewIdentityFile(filepath.Join(dst, record.Name()), b, 0o600); err != nil {
			return err
		}
	}
	return nil
}
