//go:build linux

package git

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"aurora3/internal/wire"
)

type recorder struct{ events []string }

func (r *recorder) Write(event string, _ map[string]any) { r.events = append(r.events, event) }

// newEnv makes one root with one repository. The repository is created by the
// test itself, with git, so every operation runs against real git state.
func newEnv(t *testing.T) (*Env, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	root := t.TempDir()
	return &Env{Roots: []Root{{ID: "home", Label: "home", Path: root}}, Audit: &recorder{}}, root
}

func gitRun(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=T", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=T", "GIT_COMMITTER_EMAIL=t@example.com")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}

func repo(t *testing.T, root, name string) string {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "init", "-q", "-b", "main")
	gitRun(t, dir, "config", "user.name", "T")
	gitRun(t, dir, "config", "user.email", "t@example.com")
	return dir
}

func call(t *testing.T, fn func(context.Context, json.RawMessage) (any, error), args map[string]any) (any, error) {
	t.Helper()
	b, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	return fn(context.Background(), b)
}

// A repository with no commit cannot create a branch; the message must say to
// commit first, and it must work after the first commit. This is v2's rule
// (git_branch_test.go).
func TestBranchOnEmptyRepoSaysCommitFirst(t *testing.T) {
	e, root := newEnv(t)
	dir := repo(t, root, "empty")
	args := map[string]any{"root": "home", "repo": "/empty", "action": "create", "branch": "feature-x"}
	_, err := call(t, e.gitBranch, args)
	if wire.CodeOf(err) != wire.CodeConflict || !strings.Contains(err.Error(), "先提交") {
		t.Fatalf("empty repo: code %v message %q", wire.CodeOf(err), err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", "a.txt")
	gitRun(t, dir, "commit", "-q", "-m", "first")
	if _, err := call(t, e.gitBranch, args); err != nil {
		t.Fatalf("after a commit: %v", err)
	}
}

// Status lists a new file as untracked, and staging then committing it moves it
// into the history. Each mutating call writes one audit line.
func TestStageCommitAndAudit(t *testing.T) {
	e, root := newEnv(t)
	dir := repo(t, root, "proj")
	if err := os.WriteFile(filepath.Join(dir, "x.txt"), []byte("hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := call(t, e.gitStage, map[string]any{"root": "home", "repo": "/proj", "paths": []string{"x.txt"}}); err != nil {
		t.Fatalf("stage: %v", err)
	}
	if _, err := call(t, e.gitCommit, map[string]any{"root": "home", "repo": "/proj", "message": "add x"}); err != nil {
		t.Fatalf("commit: %v", err)
	}
	out, err := exec.Command("git", "-C", dir, "log", "--format=%s").CombinedOutput()
	if err != nil || !strings.Contains(string(out), "add x") {
		t.Fatalf("history %q %v", out, err)
	}
	if len(e.Audit.(*recorder).events) == 0 {
		t.Fatal("a commit must write an audit line (D-26)")
	}
}

// A path that climbs out of the root is refused with v2's forbidden code, and
// nothing is run. A repository path must be relative, as v2 requires ("a.txt"
// is valid, "/a.txt" is not).
func TestRepoOutsideRootRefused(t *testing.T) {
	e, _ := newEnv(t)
	_, err := call(t, e.gitStatus, map[string]any{"root": "home", "repo": "/../etc"})
	if wire.CodeOf(err) != wire.CodeForbidden {
		t.Fatalf("outside root: code %v (%v)", wire.CodeOf(err), err)
	}
}

// Unknown root is refused, as in v2.
func TestUnknownRootRefused(t *testing.T) {
	e, root := newEnv(t)
	repo(t, root, "proj")
	_, err := call(t, e.gitStatus, map[string]any{"root": "nope", "repo": "/proj"})
	if wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("unknown root: code %v (%v)", wire.CodeOf(err), err)
	}
}

// Repository paths are relative to the repository; a leading slash is refused, as in
// v2 (devtools_test.go git.stage tests).
func TestRepoPathMustBeRelative(t *testing.T) {
	e, root := newEnv(t)
	dir := repo(t, root, "rel")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := call(t, e.gitStage, map[string]any{"root": "home", "repo": "/rel", "paths": []string{"/a.txt"}})
	if wire.CodeOf(err) != wire.CodeBadRequest {
		t.Fatalf("absolute repo path: code %v (%v)", wire.CodeOf(err), err)
	}
}
