package files

import (
	"io/fs"
	"os"
	"syscall"
)

// Go's FileInfo exposes Windows creation time and attributes, but not the
// NTFS file index. Including them detects ordinary same-size replacements
// even when the last write time has been preserved.
func fileIdentity(fi fs.FileInfo) (int64, int64) {
	if data, ok := fi.Sys().(*syscall.Win32FileAttributeData); ok {
		return int64(data.FileAttributes), data.CreationTime.Nanoseconds()
	}
	return 0, 0
}
func fileOwner(fi fs.FileInfo) (string, string)  { return "", "" }
func ownerFor(*os.Root, string) (int, int, bool) { return 0, 0, false }
func copyOwner(*os.Root, string, fs.FileInfo)    {}
