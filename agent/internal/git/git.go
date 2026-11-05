//go:build linux

package git

// git.*: the source control view. Every op names a repository by {root,
// repo}: repo is the root-relative path of the work tree's top folder, as
// git.repos reports it; file paths are relative to that top folder.

import (
	"aurora3/internal/paths"
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/wire"
)

type gitArgs struct {
	Root    string   `json:"root"`
	Repo    string   `json:"repo"`
	Path    string   `json:"path"`
	Paths   []string `json:"paths"`
	Rev     string   `json:"rev"`
	Message string   `json:"message"`
	Amend   bool     `json:"amend"`
	All     bool     `json:"all"`
	Branch  string   `json:"branch"`
	Create  bool     `json:"create"`
	Action  string   `json:"action"`
	Max     int      `json:"max"`
	Skip    int      `json:"skip"`
	// git_adv.go
	Content   *string `json:"content"`
	Mode      string  `json:"mode"`
	Index     int     `json:"index"`
	To        string  `json:"to"`
	Force     bool    `json:"force"`
	Untracked bool    `json:"untracked"`
	Name      string  `json:"name"`
	Graph     bool    `json:"graph"`
	// git.status: also the ignored paths (for the explorer)
	Ignored bool `json:"ignored"`
	// WithUpstream: git.log also lists the upstream's commits (those to pull)
	WithUpstream bool `json:"with_upstream"`
}

// repo opens the repository a names.
func (e *Env) repo(raw json.RawMessage) (*gitArgs, *gitCtx, string, error) {
	var a gitArgs
	if err := decode(raw, &a); err != nil {
		return nil, nil, "", err
	}
	rootAbs, abs, err := e.dirOf(a.Root, a.Repo)
	if err != nil {
		return nil, nil, "", err
	}
	g, err := gitFor(abs, e.Proxy)
	if err != nil {
		return nil, nil, "", err
	}
	for _, p := range append(append([]string{}, a.Paths...), a.Path) {
		if !validRepoPath(p) {
			return nil, nil, "", wire.Errf(wire.CodeBadRequest, "路径无效：%s", p)
		}
	}
	if a.Rev != "" && !validRev(a.Rev) {
		return nil, nil, "", wire.Errf(wire.CodeBadRequest, "版本无效")
	}
	return &a, g, rootAbs, nil
}

// validRepoPath: a path inside the work tree, never an option or outside it.
func validRepoPath(p string) bool {
	if strings.HasPrefix(p, "-") || strings.HasPrefix(p, "/") || strings.ContainsRune(p, 0) || len(p) > 4096 {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return false
		}
	}
	return true
}

var revRe = regexp.MustCompile(`^(:|:[123]|[A-Za-z0-9._/@{}-]+(\^|~[0-9]+)?)$`)

// validRev: ":" (the index), ":1" ":2" ":3" (the sides of a conflict), a ref
// or a hash, optionally followed by ^ or ~N.
func validRev(r string) bool {
	return len(r) <= 200 && !strings.HasPrefix(r, "-") && !strings.Contains(r, "..") && revRe.MatchString(r)
}

func validRef(name string) bool {
	return name != "" && len(name) <= 200 && !strings.HasPrefix(name, "-") && !strings.Contains(name, "..") && !strings.ContainsAny(name, " \t\n\x00~^:?*[\\")
}

func validHash(h string) bool {
	if len(h) < 4 || len(h) > 64 {
		return false
	}
	for _, c := range h {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func gitCall(ctx context.Context, g *gitCtx, stdin []byte, args ...string) ([]byte, error) {
	out, stderr, err := g.run(ctx, stdin, args...)
	if err != nil {
		return nil, gitErr(stderr, err)
	}
	return out, nil
}

type repoInfo struct {
	Repo string `json:"repo"`
	Name string `json:"name"`
	Top  string `json:"top"`
}

// git.repos: the repositories of a folder: the one it is inside, and those in
// its subfolders (up to three levels down).
func (e *Env) gitRepos(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root string `json:"root"`
		Path string `json:"path"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	rootAbs, abs, err := e.dirOf(a.Root, a.Path)
	if err != nil {
		return nil, err
	}
	g, err := gitFor(abs, e.Proxy)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []repoInfo{}
	add := func(top string) {
		if seen[top] {
			return
		}
		seen[top] = true
		out = append(out, repoInfo{Repo: rootRel(rootAbs, top), Name: filepath.Base(top), Top: top})
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	top, _, err := g.run(cctx, nil, "rev-parse", "--show-toplevel")
	cancel()
	if err == nil {
		if t := strings.TrimSpace(string(top)); t != "" {
			add(t)
		}
	}
	skip := paths.ForeignMounts(abs)
	deadline := time.Now().Add(4 * time.Second)
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if depth > 3 || len(out) >= 30 || ctx.Err() != nil || time.Now().After(deadline) {
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			if e.Name() == ".git" {
				add(dir)
				continue
			}
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") || paths.SkipDirs[e.Name()] {
				continue
			}
			if p := filepath.Join(dir, e.Name()); !skip[p] {
				walk(p, depth+1)
			}
		}
	}
	walk(abs, 0)
	return map[string]any{"repos": out}, nil
}

type gitFile struct {
	Path string `json:"path"`
	Orig string `json:"orig,omitempty"`
	X    string `json:"x"` // index: . M A D R C U ?
	Y    string `json:"y"` // work tree
}

type statusResult struct {
	Branch    string    `json:"branch"`
	Oid       string    `json:"oid"`
	Upstream  string    `json:"upstream"`
	Ahead     int       `json:"ahead"`
	Behind    int       `json:"behind"`
	Files     []gitFile `json:"files"`
	Truncated bool      `json:"truncated,omitempty"`
	Operation string    `json:"operation,omitempty"`
	// Ignored: paths matching .gitignore (folders end with /), when asked
	Ignored []string `json:"ignored,omitempty"`
	// Last: the commit HEAD points at; Fetched: when FETCH_HEAD was written
	Last    *commit `json:"last,omitempty"`
	Fetched int64   `json:"fetched,omitempty"`
	Stashes int     `json:"stashes"`
	// Remotes: the names of the configured remotes
	Remotes []string `json:"remotes"`
	// AheadList / BehindList: the commits to push and to pull (at most 200)
	AheadList  []string `json:"ahead_list,omitempty"`
	BehindList []string `json:"behind_list,omitempty"`
}

// git.status: branch and changed files (porcelain v2).
func (e *Env) gitStatus(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	g.env = append(g.env, "GIT_OPTIONAL_LOCKS=0")
	args := []string{"status", "--porcelain=v2", "--branch", "-z"}
	if a.Ignored {
		// "matching": an ignored folder is one entry, git does not walk into it
		args = append(args, "--ignored=matching")
	}
	out, err := gitCall(ctx, g, nil, args...)
	if err != nil {
		return nil, err
	}
	res := parseStatus(out)
	if len(res.Files) > 5000 {
		res.Files, res.Truncated = res.Files[:5000], true
	}
	if len(res.Ignored) > 3000 {
		res.Ignored = res.Ignored[:3000]
	}
	if b, _, err := g.run(ctx, nil, "log", "-1", "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%P%x00%s"); err == nil {
		if f := strings.SplitN(strings.TrimRight(string(b), "\n"), "\x00", 7); len(f) == 7 {
			t, _ := strconv.ParseInt(f[4], 10, 64)
			res.Last = &commit{Hash: f[0], Short: f[1], Author: f[2], Email: f[3], Time: t, Parents: f[5], Subject: f[6]}
		}
	}
	if res.Upstream != "" && res.Ahead > 0 {
		if b, _, err := g.run(ctx, nil, "rev-list", "--max-count=200", "@{u}..HEAD"); err == nil {
			res.AheadList = strings.Fields(string(b))
		}
	}
	if res.Upstream != "" && res.Behind > 0 {
		if b, _, err := g.run(ctx, nil, "rev-list", "--max-count=200", "HEAD..@{u}"); err == nil {
			res.BehindList = strings.Fields(string(b))
		}
	}
	res.Remotes = []string{}
	if b, _, err := g.run(ctx, nil, "remote"); err == nil {
		res.Remotes = strings.Fields(string(b))
	}
	if b, _, err := g.run(ctx, nil, "rev-parse", "--git-dir"); err == nil {
		gd := strings.TrimSpace(string(b))
		if !filepath.IsAbs(gd) {
			gd = filepath.Join(g.dir, gd)
		}
		if fi, err := os.Stat(filepath.Join(gd, "FETCH_HEAD")); err == nil {
			res.Fetched = fi.ModTime().Unix()
		}
		if b, err := os.ReadFile(filepath.Join(gd, "logs", "refs", "stash")); err == nil {
			res.Stashes = bytes.Count(b, []byte{'\n'})
		}
		for _, op := range []struct{ f, name string }{{"MERGE_HEAD", "merge"}, {"rebase-merge", "rebase"}, {"rebase-apply", "rebase"}, {"CHERRY_PICK_HEAD", "cherry-pick"}, {"REVERT_HEAD", "revert"}} {
			if _, err := os.Stat(filepath.Join(gd, op.f)); err == nil {
				res.Operation = op.name
			}
		}
	}
	return res, nil
}

func parseStatus(out []byte) statusResult {
	r := statusResult{Files: []gitFile{}}
	recs := bytes.Split(out, []byte{0})
	for i := 0; i < len(recs); i++ {
		l := string(recs[i])
		switch {
		case strings.HasPrefix(l, "# branch.oid "):
			r.Oid = strings.TrimPrefix(l, "# branch.oid ")
		case strings.HasPrefix(l, "# branch.head "):
			r.Branch = strings.TrimPrefix(l, "# branch.head ")
		case strings.HasPrefix(l, "# branch.upstream "):
			r.Upstream = strings.TrimPrefix(l, "# branch.upstream ")
		case strings.HasPrefix(l, "# branch.ab "):
			if f := strings.Fields(strings.TrimPrefix(l, "# branch.ab ")); len(f) == 2 {
				r.Ahead, _ = strconv.Atoi(strings.TrimPrefix(f[0], "+"))
				r.Behind, _ = strconv.Atoi(strings.TrimPrefix(f[1], "-"))
			}
		case strings.HasPrefix(l, "1 "):
			if f := strings.SplitN(l, " ", 9); len(f) == 9 && len(f[1]) == 2 {
				r.Files = append(r.Files, gitFile{Path: f[8], X: f[1][:1], Y: f[1][1:]})
			}
		case strings.HasPrefix(l, "2 "):
			if f := strings.SplitN(l, " ", 10); len(f) == 10 && len(f[1]) == 2 {
				gf := gitFile{Path: f[9], X: f[1][:1], Y: f[1][1:]}
				if i+1 < len(recs) {
					gf.Orig = string(recs[i+1])
					i++
				}
				r.Files = append(r.Files, gf)
			}
		case strings.HasPrefix(l, "u "):
			if f := strings.SplitN(l, " ", 11); len(f) == 11 {
				r.Files = append(r.Files, gitFile{Path: f[10], X: "U", Y: "U"})
			}
		case strings.HasPrefix(l, "? "):
			r.Files = append(r.Files, gitFile{Path: l[2:], X: "?", Y: "?"})
		case strings.HasPrefix(l, "! "):
			r.Ignored = append(r.Ignored, l[2:])
		}
	}
	return r
}

// git.show: a file as it is in a revision (":" = the index, "HEAD", a hash).
func (e *Env) gitShow(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if a.Path == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少文件")
	}
	spec := ":" + a.Path
	if len(a.Rev) == 2 && a.Rev[0] == ':' {
		spec = a.Rev + ":" + a.Path // a conflict's base / ours / theirs
	} else if a.Rev != "" && a.Rev != ":" {
		spec = a.Rev + ":" + a.Path
	}
	out, stderr, err := g.run(ctx, nil, "show", spec)
	if err != nil {
		for _, s := range []string{"does not exist", "exists on disk, but not in", "invalid object name", "bad revision", "not in the index", "unknown revision", "Not a valid object name", "but not at stage"} {
			if strings.Contains(stderr, s) {
				return map[string]any{"missing": true, "text": ""}, nil
			}
		}
		return nil, gitErr(stderr, err)
	}
	if len(out) > 8<<20 {
		return map[string]any{"too_big": true, "text": ""}, nil
	}
	if bytes.IndexByte(out[:min(len(out), 8000)], 0) >= 0 {
		return map[string]any{"binary": true, "text": ""}, nil
	}
	return map[string]any{"text": string(out)}, nil
}

func (e *Env) gitStage(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	args := []string{"add", "-A", "--"}
	if a.All || len(a.Paths) == 0 {
		args = append(args, ".")
	} else {
		args = append(args, a.Paths...)
	}
	if _, err := gitCall(ctx, g, nil, args...); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

func (e *Env) gitUnstage(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	paths := a.Paths
	if a.All || len(paths) == 0 {
		paths = []string{"."}
	}
	if _, _, err := g.run(ctx, nil, "rev-parse", "--verify", "-q", "HEAD"); err != nil {
		// no commit yet: nothing to reset to
		_, err := gitCall(ctx, g, nil, append([]string{"rm", "--cached", "-r", "-q", "--"}, paths...)...)
		return map[string]any{"ok": err == nil}, err
	}
	if _, err := gitCall(ctx, g, nil, append([]string{"reset", "-q", "HEAD", "--"}, paths...)...); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

// git.discard throws away work-tree changes of tracked files and deletes the
// untracked files and folders given (the client asks first).
func (e *Env) gitDiscard(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if len(a.Paths) == 0 {
		return nil, wire.Errf(wire.CodeBadRequest, "没有选择文件")
	}
	out, _ := gitCall(ctx, g, nil, append([]string{"ls-files", "-z", "--"}, a.Paths...)...)
	known := map[string]bool{}
	for _, f := range bytes.Split(out, []byte{0}) {
		known[string(f)] = true
	}
	var tracked, untracked []string
	for _, p := range a.Paths {
		if known[p] {
			tracked = append(tracked, p)
		} else {
			untracked = append(untracked, p)
		}
	}
	if len(tracked) > 0 {
		if _, err := gitCall(ctx, g, nil, append([]string{"checkout", "-q", "--"}, tracked...)...); err != nil {
			return nil, err
		}
	}
	if len(untracked) > 0 {
		if _, err := gitCall(ctx, g, nil, append([]string{"clean", "-f", "-d", "-q", "--"}, untracked...)...); err != nil {
			return nil, err
		}
	}
	e.Audit.Write("git.discard", map[string]any{"root": a.Root, "repo": a.Repo, "paths": a.Paths})
	return map[string]any{"ok": true}, nil
}

func (e *Env) gitCommit(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	msg := strings.TrimSpace(a.Message)
	if msg == "" && !a.Amend {
		return nil, wire.Errf(wire.CodeBadRequest, "提交说明不能为空")
	}
	args := []string{"commit", "-q", "--cleanup=strip"}
	if a.All {
		args = append(args, "-a")
	}
	if a.Amend {
		args = append(args, "--amend")
		if msg == "" {
			args = append(args, "--no-edit")
		}
	}
	var stdin []byte
	if msg != "" {
		args = append(args, "-F", "-")
		stdin = []byte(msg + "\n")
	}
	if _, err := gitCall(ctx, g, stdin, args...); err != nil {
		return nil, err
	}
	res := map[string]any{"ok": true}
	if out, err := gitCall(ctx, g, nil, "log", "-1", "--format=%h%x00%s"); err == nil {
		if f := strings.SplitN(strings.TrimSpace(string(out)), "\x00", 2); len(f) == 2 {
			res["hash"], res["subject"] = f[0], f[1]
		}
	}
	e.Audit.Write("git.commit", map[string]any{"root": a.Root, "repo": a.Repo, "amend": a.Amend})
	return res, nil
}

type branch struct {
	Name     string `json:"name"`
	Remote   bool   `json:"remote"`
	Hash     string `json:"hash"`
	Upstream string `json:"upstream,omitempty"`
	Current  bool   `json:"current"`
	Time     int64  `json:"time"`
	Subject  string `json:"subject"`
	// Ahead / Behind: commits against its upstream; Gone: the upstream was deleted
	Ahead  int  `json:"ahead,omitempty"`
	Behind int  `json:"behind,omitempty"`
	Gone   bool `json:"gone,omitempty"`
}

func (e *Env) gitBranches(ctx context.Context, raw json.RawMessage) (any, error) {
	_, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	out, err := gitCall(ctx, g, nil, "for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(refname:short)%00%(objectname:short)%00%(upstream:short)%00%(HEAD)%00%(committerdate:unix)%00%(contents:subject)%00%(upstream:track,nobracket)", "refs/heads", "refs/remotes")
	if err != nil {
		return nil, err
	}
	list := []branch{}
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Split(l, "\x00")
		if len(f) < 7 || strings.HasSuffix(f[0], "/HEAD") {
			continue
		}
		t, _ := strconv.ParseInt(f[5], 10, 64)
		b := branch{Name: f[1], Remote: strings.HasPrefix(f[0], "refs/remotes/"), Hash: f[2], Upstream: f[3], Current: f[4] == "*", Time: t, Subject: f[6]}
		if len(f) > 7 {
			b.Ahead, b.Behind, b.Gone = parseTrack(f[7])
		}
		list = append(list, b)
	}
	return map[string]any{"branches": list}, nil
}

// parseTrack reads "ahead 1, behind 2" / "gone" (for-each-ref upstream:track).
func parseTrack(s string) (ahead, behind int, gone bool) {
	for _, p := range strings.Split(s, ",") {
		k, v, _ := strings.Cut(strings.TrimSpace(p), " ")
		switch k {
		case "ahead":
			ahead, _ = strconv.Atoi(v)
		case "behind":
			behind, _ = strconv.Atoi(v)
		case "gone":
			gone = true
		}
	}
	return
}

func (e *Env) gitCheckout(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if !validRef(a.Branch) {
		return nil, wire.Errf(wire.CodeBadRequest, "分支名无效")
	}
	args := []string{"checkout", "-q"}
	if a.Create {
		args = append(args, "-b", a.Branch)
		if a.Rev != "" {
			args = append(args, a.Rev)
		}
	} else {
		args = append(args, a.Branch)
	}
	if _, err := gitCall(ctx, g, nil, args...); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

// git.sync (a stream op, so it may take minutes): fetch, pull or push.
func (e *Env) gitSync(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	go func() { // the client went away
		var b [1]byte
		_, _ = st.Read(b[:])
		cancel()
	}()
	var args []string
	switch a.Action {
	case "fetch":
		args = []string{"fetch", "--all", "--prune"}
	case "pull":
		// a fast-forward unless the client chose how to join diverged
		// histories (git >= 2.27 refuses to guess, with a cryptic message)
		switch a.Mode {
		case "merge":
			args = []string{"pull", "--no-rebase", "--no-edit"}
		case "rebase":
			args = []string{"pull", "--rebase", "--autostash"}
		default:
			args = []string{"pull", "--ff-only"}
		}
	case "push":
		args = []string{"push"}
		if out, _, err := g.run(ctx, nil, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"); err != nil || strings.TrimSpace(string(out)) == "" {
			remote := "origin"
			if rs, _, err := g.run(ctx, nil, "remote"); err == nil {
				list := strings.Fields(string(rs))
				if len(list) == 0 {
					return wire.Errf(wire.CodeConflict, "这个仓库没有远程仓库（git remote add origin <地址>）")
				}
				if !strings.Contains(" "+strings.Join(list, " ")+" ", " origin ") {
					remote = list[0]
				}
			}
			args = []string{"push", "-u", remote, "HEAD"}
		}
	case "push-tags":
		args = []string{"push", "--tags"}
	case "delete-remote":
		remote, name, ok := strings.Cut(a.Branch, "/")
		if !ok || !validRef(remote) || !validRef(name) {
			return wire.Errf(wire.CodeBadRequest, "远程分支无效")
		}
		args = []string{"push", remote, "--delete", name}
	case "push-tag":
		if !validRef(a.Name) {
			return wire.Errf(wire.CodeBadRequest, "标签名无效")
		}
		args = []string{"push", "origin", "refs/tags/" + a.Name}
	default:
		return wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	out, stderr, err := g.run(ctx, nil, args...)
	if err != nil {
		text := stderr + "\n" + string(out)
		reason := syncFailure(a.Action, text)
		if reason == "" && a.Action == "pull" && operationOf(ctx, g) != "" {
			reason = "conflicts" // the merge or rebase stopped at a conflict
		}
		if reason != "" {
			e.Audit.Write("git."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo, "result": reason})
			return wire.WriteJSON(st, wire.OKResponse(map[string]any{"ok": false, "reason": reason, "output": tailText(text, 3000)}))
		}
		return gitErr(stderr, err)
	}
	e.Audit.Write("git."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo})
	return wire.WriteJSON(st, wire.OKResponse(map[string]any{"ok": true, "output": tailText(stderr, 2000)}))
}

// syncFailure: the failures of pull and push the client resolves with a
// question rather than an error: diverged histories, a rejected push,
// local changes in the way.
func syncFailure(action, text string) string {
	switch {
	case action == "pull" && (strings.Contains(text, "Not possible to fast-forward") || strings.Contains(text, "divergent branches") || strings.Contains(text, "fatal: Not possible to fast")):
		return "diverged"
	case action == "push" && strings.Contains(text, "[rejected]") && (strings.Contains(text, "fetch first") || strings.Contains(text, "non-fast-forward")):
		return "rejected"
	case strings.Contains(text, "would be overwritten by merge") || strings.Contains(text, "Please commit your changes or stash them"):
		return "dirty"
	}
	return ""
}

func tailText(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

type commit struct {
	Hash    string `json:"hash"`
	Short   string `json:"short"`
	Author  string `json:"author"`
	Email   string `json:"email"`
	Time    int64  `json:"time"`
	Refs    string `json:"refs,omitempty"`
	Parents string `json:"parents,omitempty"`
	Subject string `json:"subject"`
}

func (e *Env) gitLog(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if a.Max <= 0 || a.Max > 500 {
		a.Max = 100
	}
	args := []string{"log", "--format=%H%x00%h%x00%an%x00%ae%x00%at%x00%D%x00%P%x00%s%x1e", "-n", strconv.Itoa(a.Max), "--skip", strconv.Itoa(max(a.Skip, 0))}
	if a.Graph {
		args = append(args, "--topo-order")
		if a.All {
			args = append(args, "--branches", "--remotes", "--tags", "HEAD")
		} else if a.WithUpstream && a.Rev == "" && a.Path == "" {
			if _, _, err := g.run(ctx, nil, "rev-parse", "--verify", "-q", "@{u}"); err == nil {
				args = append(args, "HEAD", "@{u}")
			}
		}
	}
	if a.Rev != "" {
		args = append(args, a.Rev)
	}
	if a.Path != "" {
		if !validRepoPath(a.Path) {
			return nil, wire.Errf(wire.CodeBadRequest, "路径无效")
		}
		// --follow (renames) works for one file only; a folder's history is plain
		if fi, err := os.Stat(filepath.Join(g.dir, a.Path)); err == nil && fi.Mode().IsRegular() {
			args = append(args, "--follow")
		}
		args = append(args, "--", a.Path)
	}
	out, stderr, err := g.run(ctx, nil, args...)
	if err != nil {
		if strings.Contains(stderr, "does not have any commits") || strings.Contains(stderr, "bad default revision") {
			return map[string]any{"commits": []commit{}}, nil
		}
		return nil, gitErr(stderr, err)
	}
	list := []commit{}
	for _, rec := range strings.Split(string(out), "\x1e") {
		f := strings.Split(strings.TrimLeft(rec, "\n"), "\x00")
		if len(f) < 8 {
			continue
		}
		t, _ := strconv.ParseInt(f[4], 10, 64)
		list = append(list, commit{Hash: f[0], Short: f[1], Author: f[2], Email: f[3], Time: t, Refs: f[5], Parents: f[6], Subject: f[7]})
	}
	return map[string]any{"commits": list}, nil
}

// git.commitFiles: the message and the files of a commit.
func (e *Env) gitCommitFiles(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if !validHash(a.Rev) {
		return nil, wire.Errf(wire.CodeBadRequest, "提交无效")
	}
	msg, err := gitCall(ctx, g, nil, "show", "-s", "--format=%B", a.Rev)
	if err != nil {
		return nil, err
	}
	out, err := gitCall(ctx, g, nil, "show", "--format=", "--name-status", "-z", "-M", "--first-parent", a.Rev)
	if err != nil {
		return nil, err
	}
	return map[string]any{"message": strings.TrimSpace(string(msg)), "files": parseNameStatus(out)}, nil
}

func parseNameStatus(out []byte) []gitFile {
	recs := bytes.Split(bytes.TrimLeft(out, "\n"), []byte{0})
	files := []gitFile{}
	for i := 0; i < len(recs); i++ {
		st := strings.TrimSpace(string(recs[i]))
		if st == "" {
			continue
		}
		f := gitFile{X: st[:1]}
		if (st[0] == 'R' || st[0] == 'C') && i+2 < len(recs) {
			f.Orig, f.Path = string(recs[i+1]), string(recs[i+2])
			i += 2
		} else if i+1 < len(recs) {
			f.Path = string(recs[i+1])
			i++
		} else {
			break
		}
		files = append(files, f)
	}
	return files
}

// git.blame: who last changed each line of the committed file.
func (e *Env) gitBlame(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if a.Path == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少文件")
	}
	out, stderr, err := g.run(ctx, nil, "blame", "--porcelain", "--", a.Path)
	if err != nil {
		if strings.Contains(stderr, "no such path") || strings.Contains(stderr, "does not have any commits") {
			return map[string]any{"commits": []any{}, "lines": []int{}}, nil
		}
		return nil, gitErr(stderr, err)
	}
	return parseBlame(out), nil
}

type blameCommit struct {
	Hash        string `json:"hash"`
	Short       string `json:"short"`
	Author      string `json:"author"`
	Time        int64  `json:"time"`
	Summary     string `json:"summary"`
	Uncommitted bool   `json:"uncommitted,omitempty"`
}

// parseBlame: the commits, and for each line the index of its commit.
func parseBlame(out []byte) map[string]any {
	idx := map[string]int{}
	list := []*blameCommit{}
	lines := []int{}
	cur := -1
	for _, l := range strings.Split(string(out), "\n") {
		if l == "" {
			continue
		}
		if l[0] == '\t' {
			if cur >= 0 {
				lines = append(lines, cur)
			}
			continue
		}
		f := strings.SplitN(l, " ", 2)
		if len(f[0]) == 40 && validHash(f[0]) {
			i, ok := idx[f[0]]
			if !ok {
				i = len(list)
				idx[f[0]] = i
				list = append(list, &blameCommit{Hash: f[0], Short: f[0][:8], Uncommitted: strings.Trim(f[0], "0") == ""})
			}
			cur = i
			continue
		}
		if cur < 0 || len(f) < 2 {
			continue
		}
		c := list[cur]
		switch f[0] {
		case "author":
			c.Author = f[1]
		case "author-time":
			c.Time, _ = strconv.ParseInt(f[1], 10, 64)
		case "summary":
			c.Summary = f[1]
		}
	}
	return map[string]any{"commits": list, "lines": lines}
}