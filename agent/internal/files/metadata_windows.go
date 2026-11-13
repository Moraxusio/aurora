package files

import (
	"io/fs"
	"os"
)

func fileIdentity(fi fs.FileInfo) (int64, int64) { return 0, 0 }
func fileOwner(fi fs.FileInfo) (string, string)  { return "", "" }
func ownerFor(*os.Root, string) (int, int, bool) { return 0, 0, false }
func copyOwner(*os.Root, string, fs.FileInfo)    {}
