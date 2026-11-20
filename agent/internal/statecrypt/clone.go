//go:build linux || windows

package statecrypt

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

func overlaps(a, b string) bool {
	inside := func(root, name string) bool {
		rel, err := filepath.Rel(root, name)
		return err == nil && (rel == "." || filepath.IsLocal(rel))
	}
	return inside(a, b) || inside(b, a)
}

// CloneDirectory stages only new data under a private sibling of final and
// publishes it once, without overwriting an existing destination. The copy
// routine must read the stopped legacy source and never modify it.
func CloneDirectory(source, final string, copy func(stage string, names []string) error) error {
	root, err := OpenStateDir(source)
	if err != nil {
		return err
	}
	defer root.Close()
	unlock, err := openWriterLock(source, false)
	if err == nil {
		defer unlock()
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("源状态仍被占用或无法验证其写入锁：%w", err)
	}
	if overlaps(source, final) {
		return errors.New("克隆目标必须是独立、规范的绝对路径")
	}
	entries, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, ent := range entries {
		if !ent.IsDir() && !ent.Type().IsRegular() {
			return fmt.Errorf("旧状态包含非普通文件：%s", ent.Name())
		}
		names = append(names, ent.Name())
	}
	return StageNewDirectory(final, func(stage string) error { return copy(stage, names) })
}

// StageNewDirectory publishes a private, fully populated state directory on
// the same volume, without replacing any existing destination.
func StageNewDirectory(final string, populate func(stage string) error) error {
	if !filepath.IsAbs(final) || filepath.Clean(final) != final {
		return errors.New("目标必须是规范的绝对路径")
	}
	parent := filepath.Dir(final)
	if err := ordinaryDir(parent); err != nil {
		return err
	}
	if _, err := os.Lstat(final); !errors.Is(err, os.ErrNotExist) {
		if err != nil {
			return err
		}
		return errors.New("状态目标已存在，拒绝覆盖")
	}
	stage, err := os.MkdirTemp(parent, ".aurora-state-stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	if err := PrivateDirectory(stage); err != nil {
		return err
	}
	if err := populate(stage); err != nil {
		return err
	}
	if err := filepath.WalkDir(stage, func(path string, ent fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if ent.IsDir() {
			return FlushDirectory(path)
		}
		return nil
	}); err != nil {
		return err
	}
	return PublishDirectory(stage, final)
}
