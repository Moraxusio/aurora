//go:build linux || windows

package files

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// CloneLegacyReceipts migrates already-committed query records only. It does
// not apply any request in those records or open workspace files.
func CloneLegacyReceipts(source, stage string, codec *statecrypt.Codec) error {
	legacy, err := statecrypt.OpenStateDir(filepath.Join(source, replacementReceipts))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer legacy.Close()
	items, err := fs.ReadDir(legacy.FS(), ".")
	if err != nil {
		return err
	}
	if len(items) > maxReplacementReceipts {
		return fmt.Errorf("旧收据数量超过迁移上限")
	}
	dest := filepath.Join(stage, replacementReceipts)
	if err := os.Mkdir(dest, 0o700); err != nil {
		return err
	}
	for _, item := range items {
		name := item.Name()
		id, valid := strings.CutSuffix(name, ".json")
		if !valid || !validReceiptID(id) || !item.Type().IsRegular() {
			return fmt.Errorf("旧收据目录有未识别的记录：%s", name)
		}
		r, err := readReceipt(legacy, name)
		if err != nil {
			return err
		}
		plain, err := json.Marshal(r)
		if err != nil {
			return err
		}
		sealed, err := codec.Seal("paste-receipt:"+name, plain)
		clear(plain)
		if err != nil {
			return err
		}
		if err := wire.WriteNewIdentityFile(filepath.Join(dest, name), sealed, 0o600); err != nil {
			return err
		}
	}
	return nil
}
