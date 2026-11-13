//go:build linux || windows

// Package paths holds the path rules shared by the services: resolving a
// client path inside a configured root, and the mount points a walk must not
// enter. It sits in the kernel so that services never import each other (D-40).
package paths

import (
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"

	"aurora3/internal/wire"
)

// LocalFS lists the filesystem types that are local disks, not network mounts.
var LocalFS = map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "f2fs": true, "vfat": true, "zfs": true, "jfs": true}

// ReadFile returns the file's text, or "" when it cannot be read.
func ReadFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

// Within reports whether p is root or lies below it.
func Within(root, p string) bool {
	if runtime.GOOS == "windows" {
		r, err := filepath.Rel(root, p)
		return err == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) && !filepath.IsAbs(r)
	}
	return root == "/" || p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// Clean validates a client path ("/a/b") and returns it relative to the root
// ("a/b", or "." for the root itself). It refuses paths that climb out.
func Clean(p string) (string, error) {
	return cleanRel(p)
}

// ForeignMounts returns the mount points below abs that a walk must not enter:
// network and virtual filesystems, plus /proc, /sys, /dev and /run.
func ForeignMounts(abs string) map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(ReadFile("/proc/mounts"), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		mnt := strings.ReplaceAll(f[1], "\\040", " ")
		if mnt == abs || !Within(abs, mnt) {
			continue
		}
		if !LocalFS[f[2]] || mnt == "/proc" || mnt == "/sys" || mnt == "/dev" || mnt == "/run" {
			out[mnt] = true
		}
	}
	for _, p := range []string{"/proc", "/sys", "/dev", "/run"} {
		if abs == "/" {
			out[p] = true
		}
	}
	return out
}

// IsFile reports whether path is a regular file.
func IsFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// Resolve maps a root-relative client path to its absolute, symlink-checked
// location. It refuses a path that resolves outside the root. rootAbs is the
// root's real path; the caller opens the root to check it exists.
func Resolve(rootAbs, p string) (string, error) {
	rel, err := cleanRel(p)
	if err != nil {
		return "", err
	}
	if real, e := filepath.EvalSymlinks(rootAbs); e == nil {
		rootAbs = real
	}
	abs, err := filepath.EvalSymlinks(filepath.Join(rootAbs, rel))
	if err != nil {
		return "", err
	}
	if !Within(rootAbs, abs) {
		return "", ErrOutside
	}
	return abs, nil
}

// ErrOutside is returned when a path resolves outside its root.
var ErrOutside = errOutside{}

type errOutside struct{}

func (errOutside) Error() string { return "path outside the root" }

func cleanRel(p string) (string, error) {
	if len(p) > 4096 || strings.ContainsAny(p, "\x00\\") {
		return "", ErrInvalid
	}
	for _, part := range strings.Split(p, "/") {
		if runtime.GOOS == "windows" && part != "" && part != "." {
			if strings.ContainsAny(part, `:<>"|?*`) || strings.TrimRight(part, " .") != part || !filepath.IsLocal(part) {
				return "", ErrInvalid
			}
		}
		if part == ".." {
			return "", ErrOutside
		}
	}
	rel := strings.TrimPrefix(path.Clean("/"+p), "/")
	if rel == "" {
		rel = "."
	}
	return rel, nil
}

// ErrInvalid is returned for a malformed client path.
var ErrInvalid = errInvalid{}

type errInvalid struct{}

func (errInvalid) Error() string { return "invalid path" }

// WireError maps a path error to the wire error v2 returned for it, so the
// client sees the same code and message. Other errors pass through unchanged.
func WireError(err error) error {
	switch err {
	case ErrOutside:
		return wire.Errf(wire.CodeForbidden, "不允许访问根目录以外的路径")
	case ErrInvalid:
		return wire.Errf(wire.CodeBadRequest, "路径无效")
	}
	return err
}

// SkipDirs are directories a walk does not enter: VCS data, caches, and installed
// packages nobody edits. Shared by search and git.
var SkipDirs = map[string]bool{
	".git": true, ".hg": true, ".svn": true, "node_modules": true, "__pycache__": true,
	".venv": true, "venv": true, ".mypy_cache": true, ".pytest_cache": true, ".ruff_cache": true,
	".tox": true, ".cache": true, ".idea": true, ".gradle": true,
	// installed Python packages: thousands of files nobody edits
	"site-packages": true, "dist-packages": true, ".conda": true, ".npm": true, ".nvm": true,
}
