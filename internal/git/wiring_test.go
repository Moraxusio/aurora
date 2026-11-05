//go:build linux

package git

import (
	"aurora3/internal/files"
)

// The git service must satisfy the interface search consumes. This fails the
// build if the method set drifts, so the wiring cannot silently break.
var (
	_ files.RepoRunner = Repos{}
	_ files.Runner     = Runner{}
)
