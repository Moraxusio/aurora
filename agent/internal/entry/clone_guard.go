//go:build linux || windows

package entry

import (
	"fmt"
	"os"
	"path/filepath"

	"aurora3/internal/statecrypt"
)

func CheckLegacyCloneNames(source string, names []string, local bool) error {
	for _, name := range names {
		switch name {
		case "agent-id", "agent.crt", "agent.key", "ai", "paste-receipts", statecrypt.WriterFile:
		case "local-agent.json":
			if !local {
				return fmt.Errorf("拒绝克隆未知的 Linux 状态：%s", name)
			}
		case "file-transactions":
			root, err := statecrypt.OpenStateDir(filepath.Join(source, name))
			if err != nil {
				return err
			}
			items, err := os.ReadDir(root.Name())
			root.Close()
			if err != nil || len(items) != 0 {
				return fmt.Errorf("旧版仍有未处理的文件事务；请先用原版本恢复")
			}
		default:
			return fmt.Errorf("拒绝忽略暂不支持迁移的状态：%s", name)
		}
	}
	return nil
}
