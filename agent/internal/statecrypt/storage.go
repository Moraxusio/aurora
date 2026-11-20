//go:build linux || windows

package statecrypt

import (
	"errors"
	"io"
	"os"
	"path/filepath"
)

const WriterFile = ".aurora-state-writer"
const KeyFile = ".aurora-state-key"
const ProtectedMarker = ".aurora-protected-v1"

// ReadRegular reads a bounded, non-symlink state file. Keep the containing
// root open so all metadata and data are obtained from the same directory.
func ReadRegular(root *os.Root, name string, max int64) ([]byte, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > max {
		return nil, errors.New("状态记录不是有效的普通文件")
	}
	f, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, errors.New("状态记录在打开时已变化")
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err == nil && int64(len(b)) > max {
		return nil, errors.New("状态记录超过大小上限")
	}
	return b, err
}

// CheckNewDir is used to distinguish explicit fresh initialization from an
// existing store with a missing key. A missing key never opens old state.
func CheckNewDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != WriterFile || !entry.Type().IsRegular() {
			return errors.New("目录已有状态；拒绝初始化或替换密钥")
		}
	}
	return nil
}

func OpenStateDir(dir string) (*os.Root, error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return nil, errors.New("状态目录必须是规范绝对路径")
	}
	if err := ordinaryDir(dir); err != nil {
		return nil, err
	}
	return os.OpenRoot(dir)
}

func HasKeyFile(dir string) (bool, error) {
	for _, name := range []string{ProtectedMarker, KeyFile} {
		_, err := os.Lstat(filepath.Join(dir, name))
		if !errors.Is(err, os.ErrNotExist) {
			return err == nil, err
		}
	}
	return false, nil
}

const MarkerValue = "aurora-protected-v1\n"
