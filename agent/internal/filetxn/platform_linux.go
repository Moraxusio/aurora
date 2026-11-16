package filetxn

import (
	"os"
	"syscall"
)

func modesEqual(a, b os.FileMode) bool { return a == b }

func ownership(fi os.FileInfo) (int, int) {
	if s, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(s.Uid), int(s.Gid)
	}
	return -1, -1
}

func setOwnership(f *os.File, uid, gid int) error {
	if os.Geteuid() != 0 || uid < 0 || gid < 0 {
		return nil
	}
	return f.Chown(uid, gid)
}

func syncDirectory(root *os.Root, path string) error {
	d, err := root.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
