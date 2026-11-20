package statecrypt

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

func ordinaryDir(dir string) error {
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return errors.New("状态目录不是普通目录")
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return err
	}
	if real != dir {
		return errors.New("拒绝经符号链接访问状态目录")
	}
	return nil
}

func LockWriter(dir string) (func(), error) {
	return openWriterLock(dir, true)
}

func openWriterLock(dir string, create bool) (func(), error) {
	if err := ordinaryDir(dir); err != nil {
		return nil, err
	}
	dirFD, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dirFD)
	flags := unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_RDWR | unix.O_CLOEXEC
	if create {
		flags |= unix.O_CREAT
	}
	fd, err := unix.Openat(dirFD, WriterFile, flags, 0o600)
	if err != nil {
		return nil, err
	}
	var info unix.Stat_t
	if err := unix.Fstat(fd, &info); err != nil || info.Mode&unix.S_IFMT != unix.S_IFREG ||
		info.Mode&0o077 != 0 || info.Nlink != 1 || info.Uid != uint32(os.Geteuid()) {
		_ = unix.Close(fd)
		return nil, errors.New("无法验证状态目录写入锁")
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	return func() { _ = unix.Close(fd) }, nil
}

func ReplaceFile(stage, final string) error {
	dir, err := os.Open(filepath.Dir(final))
	if err != nil {
		return err
	}
	defer dir.Close()
	if err := os.Rename(stage, final); err != nil {
		return err
	}
	return dir.Sync()
}

func PublishDirectory(stage, final string) error {
	parent, err := os.Open(filepath.Dir(final))
	if err != nil {
		return err
	}
	defer parent.Close()
	if err := unix.Renameat2(unix.AT_FDCWD, stage, unix.AT_FDCWD, final, unix.RENAME_NOREPLACE); err != nil {
		return err
	}
	return parent.Sync()
}

func PrivateDirectory(dir string) error {
	if err := ordinaryDir(dir); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

func FlushDirectory(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
