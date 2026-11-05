//go:build linux

package files

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// fakeRunner stands in for the git service in tests.
type fakeRunner struct {
	names []string
	err   error
}

func (f fakeRunner) LsFiles(ctx context.Context, limit int) ([]string, bool, error) {
	if f.err != nil {
		return nil, false, f.err
	}
	if len(f.names) > limit {
		return f.names[:limit], true, nil
	}
	return f.names, false, nil
}

type fakeRepos struct {
	r   Runner
	err error
}

func (f fakeRepos) Runner(dir string) (Runner, error) { return f.r, f.err }

// Runner is the interface search consumes; this compile-time check fails the
// build if the shapes stop matching.
var _ Runner = fakeRunner{}

func tree(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, name := range []string{"a.txt", "sub/b.txt"} {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// With a runner, search returns the runner's names and labels them "git".
func TestListFilesUsesRunner(t *testing.T) {
	e := &Env{Repos: fakeRepos{r: fakeRunner{names: []string{"one.go", "two.go"}}}}
	files, via, truncated, _ := e.listFiles(context.Background(), tree(t))
	if via != "git" || truncated {
		t.Fatalf("via=%q truncated=%v, want git and not truncated", via, truncated)
	}
	if len(files) != 2 || files[0] != "one.go" {
		t.Fatalf("files %v", files)
	}
}

// When the runner fails, search walks the directory itself, as v2 does.
func TestListFilesFallsBackToWalk(t *testing.T) {
	dir := tree(t)
	e := &Env{Repos: fakeRepos{r: fakeRunner{err: errors.New("git missing")}}}
	files, via, _, _ := e.listFiles(context.Background(), dir)
	if via == "git" {
		t.Fatalf("via=%q after a runner failure; must walk", via)
	}
	if len(files) < 2 {
		t.Fatalf("walk found %v, want both files", files)
	}
}

// With no runner at all (git service off), search walks the directory.
func TestListFilesWithoutRunnerWalks(t *testing.T) {
	dir := tree(t)
	e := &Env{}
	files, via, _, _ := e.listFiles(context.Background(), dir)
	if via == "git" || len(files) < 2 {
		t.Fatalf("via=%q files=%v, want a plain walk", via, files)
	}
}

// A runner that reports the cap is reported as truncated, and the list is
// exactly the cap long.
func TestListFilesReportsCap(t *testing.T) {
	names := make([]string, listMax+10)
	for i := range names {
		names[i] = fmt.Sprintf("f%d", i)
	}
	e := &Env{Repos: fakeRepos{r: fakeRunner{names: names}}}
	files, via, truncated, _ := e.listFiles(context.Background(), tree(t))
	if via != "git" || !truncated {
		t.Fatalf("via=%q truncated=%v, want git and truncated", via, truncated)
	}
	if len(files) != listMax {
		t.Fatalf("got %d names, want exactly listMax (%d)", len(files), listMax)
	}
}
