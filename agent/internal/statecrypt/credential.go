package statecrypt

import (
	"errors"
	"io"
	"os"
	"path/filepath"
)

// Credential opens the fixed name handed to Aurora by the OS. No state key
// bytes are accepted through an environment variable or command line.
func Credential() (*Codec, error) {
	dir := os.Getenv("CREDENTIALS_DIRECTORY")
	if dir == "" || !filepath.IsAbs(dir) {
		return nil, errors.New("缺少独立的 systemd 凭据目录")
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	const name = "aurora-state-key"
	fi, err := root.Lstat(name)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != KeyBytes || fi.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("缺少 32 字节的私有凭据 aurora-state-key，或权限不符合要求")
	}
	f, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(fi, opened) {
		return nil, errors.New("状态密钥在打开时已变化")
	}
	data, err := io.ReadAll(io.LimitReader(f, KeyBytes+1))
	defer clear(data)
	if err != nil {
		return nil, err
	}
	return New(data)
}
