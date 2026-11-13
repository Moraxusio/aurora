//go:build linux || windows

package files

import "context"

// Runner runs git for one directory. The git service provides it; the files
// service only sees this interface, never git's environment or the terminal
// service's session settings (D-40).
type Runner interface {
	// LsFiles returns tracked and untracked, non-ignored files below the
	// runner's directory, relative to it. It stops after limit names and
	// reports that it did so through truncated, so the caller can cap a huge
	// repository the way search does without reading all of it.
	LsFiles(ctx context.Context, limit int) (names []string, truncated bool, err error)
}

// RepoRunner returns a Runner for dir. It fails when git is not available or
// the git service is switched off; search then walks the directory itself, as
// it does without git.
type RepoRunner interface {
	Runner(dir string) (Runner, error)
}
