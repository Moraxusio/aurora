//go:build linux

package git

import (
	"bufio"
	"context"
	"os/exec"
	"time"

	"aurora3/internal/files"
)

// lsFilesTimeout bounds one git ls-files run, as v2 did for search (15 s).
const lsFilesTimeout = 15 * time.Second

// Runner is one directory's git context. It implements files.Runner.
type Runner struct {
	g *gitCtx
}

// LsFiles lists tracked and untracked, non-ignored files below the directory,
// relative to it. It reads at most limit names. At the limit it stops git and
// reports truncated; the names read so far are returned. On a git failure it
// returns the names read so far with an error, so the caller can fall back to
// a walk.
func (r Runner) LsFiles(ctx context.Context, limit int) ([]string, bool, error) {
	cctx, cancel := context.WithTimeout(ctx, lsFilesTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, r.g.exe, "-c", "safe.directory=*", "-c", "core.quotepath=off", "ls-files", "-co", "--exclude-standard", "-z")
	cmd.Dir, cmd.Env = r.g.dir, r.g.env
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, false, err
	}
	if err := cmd.Start(); err != nil {
		return nil, false, err
	}
	var files []string
	truncated := false
	sc := bufio.NewScanner(out)
	sc.Split(nulSplit)
	for sc.Scan() {
		if len(files) >= limit {
			truncated = true
			_ = cmd.Process.Kill()
			break
		}
		files = append(files, sc.Text())
	}
	waitErr := cmd.Wait()
	if truncated {
		return files, true, nil
	}
	if waitErr != nil {
		return files, false, waitErr
	}
	return files, false, sc.Err()
}

func nulSplit(data []byte, atEOF bool) (int, []byte, error) {
	for i, b := range data {
		if b == 0 {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

// Repos provides a Runner per directory. It satisfies files.RepoRunner.
type Repos struct {
	// Proxy is the same hook as Env.Proxy (D-69).
	Proxy func() map[string]string
}

// Runner returns a runner for dir. It fails when git is missing, and the
// caller then walks the directory as v2 did.
func (r Repos) Runner(dir string) (files.Runner, error) {
	g, err := gitFor(dir, r.Proxy)
	if err != nil {
		return nil, err
	}
	return Runner{g: g}, nil
}
