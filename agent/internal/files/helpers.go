//go:build linux || windows

package files

import (
	"aurora3/internal/paths"
)

// Thin wrappers over the kernel's path rules (internal/paths). The bodies live
// in one place, shared with the git service (D-40).

var localFS = paths.LocalFS

func readFile(p string) string { return paths.ReadFile(p) }

func within(root, p string) bool { return paths.Within(root, p) }
