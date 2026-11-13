package files

import (
	"io/fs"
	"os"
	"path"
	"syscall"
)

func fileIdentity(fi fs.FileInfo) (int64, int64) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int64(st.Ino), st.Ctim.Sec*1e9 + st.Ctim.Nsec
	}
	return 0, 0
}
func fileOwner(fi fs.FileInfo) (string, string) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return idNames.user(st.Uid), idNames.group(st.Gid)
	}
	return "", ""
}
func ownerFor(root *os.Root, rel string) (int, int, bool) {
	if os.Geteuid() != 0 {
		return 0, 0, false
	}
	fi, err := root.Lstat(rel)
	if err != nil {
		fi, err = root.Stat(path.Dir(rel))
	}
	if err != nil {
		return 0, 0, false
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid), int(st.Gid), true
	}
	return 0, 0, false
}
func copyOwner(dst *os.Root, name string, fi fs.FileInfo) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && os.Geteuid() == 0 {
		_ = dst.Lchown(name, int(st.Uid), int(st.Gid))
	}
}
