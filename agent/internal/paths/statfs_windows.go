package paths

import (
	"golang.org/x/sys/windows"
	"os"
)

type DiskStat struct {
	Blocks, Bavail uint64
	Bsize          int64
}

func StatfsBounded(p string) (DiskStat, bool) {
	fi, err := os.Stat(p)
	if err != nil || !fi.IsDir() {
		return DiskStat{}, false
	}
	u, err := windows.UTF16PtrFromString(p)
	if err != nil {
		return DiskStat{}, false
	}
	var free, total, unused uint64
	err = windows.GetDiskFreeSpaceEx(u, &free, &total, &unused)
	return DiskStat{Blocks: total, Bavail: free, Bsize: 1}, err == nil
}
