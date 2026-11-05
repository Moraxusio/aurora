//go:build linux

package files

import (
	"os"
	"strings"
)

// Copied from v2 internal/agent/monitor.go and gitrun.go (pure functions).

// localFS lists the filesystem types that are local disks, not network mounts.
var localFS = map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "f2fs": true, "vfat": true, "zfs": true, "jfs": true}

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

func within(root, p string) bool {
	return root == "/" || p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}
