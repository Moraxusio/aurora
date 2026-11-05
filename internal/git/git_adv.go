//go:build linux

package git

// The rest of VS Code's git: staging part of a file (a hunk), the stash,
// merge / rebase / cherry-pick / revert with their continue and abort,
// reset, tags and branch management. Conflicts are an outcome, not an
// error: the answer says so and the status lists the conflicted files.

import (
	"aurora3/internal/paths"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"aurora3/internal/wire"
)

// git.stageContent puts content into the index as the file's staged text
// (staging or unstaging single hunks), without touching the work tree.
func (e *Env) gitStageContent(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if a.Path == "" || a.Content == nil || len(*a.Content) > 32<<20 {
		return nil, wire.Errf(wire.CodeBadRequest, "参数无效")
	}
	out, err := gitCall(ctx, g, []byte(*a.Content), "hash-object", "-w", "--stdin", "--path="+a.Path)
	if err != nil {
		return nil, err
	}
	hash := strings.TrimSpace(string(out))
	if !validHash(hash) {
		return nil, wire.Errf(wire.CodeInternal, "git hash-object 返回无效")
	}
	mode := "100644"
	if ls, err := gitCall(ctx, g, nil, "ls-files", "-s", "--", a.Path); err == nil {
		if f := strings.Fields(string(ls)); len(f) >= 1 && (f[0] == "100755" || f[0] == "100644" || f[0] == "120000") {
			mode = f[0]
		}
	}
	if _, err := gitCall(ctx, g, nil, "update-index", "--add", "--cacheinfo", mode+","+hash+","+a.Path); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

type stashEntry struct {
	Index   int    `json:"index"`
	Ref     string `json:"ref"`
	Hash    string `json:"hash"`
	Message string `json:"message"`
	Time    int64  `json:"time"`
}

func (e *Env) gitStash(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	ref := "stash@{" + strconv.Itoa(max(a.Index, 0)) + "}"
	switch a.Action {
	case "list":
		out, stderr, err := g.run(ctx, nil, "stash", "list", "--format=%gd%x00%H%x00%ct%x00%gs")
		if err != nil {
			return nil, gitErr(stderr, err)
		}
		list := []stashEntry{}
		for i, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			f := strings.Split(l, "\x00")
			if len(f) < 4 {
				continue
			}
			t, _ := strconv.ParseInt(f[2], 10, 64)
			list = append(list, stashEntry{Index: i, Ref: f[0], Hash: f[1], Time: t, Message: f[3]})
		}
		return map[string]any{"stashes": list}, nil
	case "push":
		args := []string{"stash", "push"}
		if a.Untracked {
			args = append(args, "--include-untracked")
		}
		if a.Mode == "staged" {
			args = append(args, "--staged")
		}
		if m := strings.TrimSpace(a.Message); m != "" {
			args = append(args, "-m", m)
		}
		if len(a.Paths) > 0 {
			args = append(append(args, "--"), a.Paths...)
		}
		out, err := gitCall(ctx, g, nil, args...)
		if err != nil {
			return nil, err
		}
		if strings.Contains(string(out), "No local changes") {
			return nil, wire.Errf(wire.CodeConflict, "没有可以储藏的更改")
		}
	case "apply", "pop":
		args := []string{"stash", a.Action}
		if a.Mode == "index" {
			args = append(args, "--index")
		}
		_, stderr, err := g.run(ctx, nil, append(args, ref)...)
		if err != nil {
			if strings.Contains(stderr, "CONFLICT") || strings.Contains(stderr, "conflict") {
				return map[string]any{"ok": true, "conflicts": true, "output": tailText(stderr, 2000)}, nil
			}
			return nil, gitErr(stderr, err)
		}
	case "drop":
		if _, err := gitCall(ctx, g, nil, "stash", "drop", ref); err != nil {
			return nil, err
		}
	case "clear":
		if _, err := gitCall(ctx, g, nil, "stash", "clear"); err != nil {
			return nil, err
		}
	case "files":
		out, err := gitCall(ctx, g, nil, "stash", "show", "--name-status", "--include-untracked", "-z", ref)
		if err != nil {
			// older git: no --include-untracked
			if out, err = gitCall(ctx, g, nil, "stash", "show", "--name-status", "-z", ref); err != nil {
				return nil, err
			}
		}
		return map[string]any{"files": parseNameStatus(out)}, nil
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	e.Audit.Write("git.stash."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo})
	return map[string]any{"ok": true}, nil
}

// git.op: merge, rebase, cherry-pick, revert, reset, and continue / abort /
// skip of the operation in progress.
func (e *Env) gitOp(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	g.env = append(g.env, "GIT_EDITOR=true", "GIT_SEQUENCE_EDITOR=true", "GIT_MERGE_AUTOEDIT=no")
	needRev := func() error {
		if a.Rev == "" || a.Rev == ":" || !validRev(a.Rev) {
			return wire.Errf(wire.CodeBadRequest, "版本无效")
		}
		return nil
	}
	var args []string
	switch a.Action {
	case "merge":
		if err := needRev(); err != nil {
			return nil, err
		}
		args = []string{"merge", "--no-edit"}
		switch a.Mode {
		case "ff-only":
			args = append(args, "--ff-only")
		case "no-ff":
			args = append(args, "--no-ff")
		case "squash":
			args = append(args, "--squash")
		}
		args = append(args, a.Rev)
	case "rebase":
		if err := needRev(); err != nil {
			return nil, err
		}
		args = []string{"rebase", a.Rev}
	case "cherry-pick":
		if !validHash(a.Rev) {
			return nil, wire.Errf(wire.CodeBadRequest, "提交无效")
		}
		args = []string{"cherry-pick", a.Rev}
	case "revert":
		if !validHash(a.Rev) {
			return nil, wire.Errf(wire.CodeBadRequest, "提交无效")
		}
		args = []string{"revert", "--no-edit", a.Rev}
	case "reset":
		if err := needRev(); err != nil {
			return nil, err
		}
		if a.Mode != "soft" && a.Mode != "mixed" && a.Mode != "hard" {
			return nil, wire.Errf(wire.CodeBadRequest, "重置方式无效")
		}
		args = []string{"reset", "-q", "--" + a.Mode, a.Rev}
	case "continue", "abort", "skip":
		op := operationOf(ctx, g)
		if op == "" {
			return nil, wire.Errf(wire.CodeConflict, "没有正在进行的合并、变基、拣选或还原")
		}
		if a.Action == "skip" && op != "rebase" && op != "cherry-pick" && op != "revert" {
			return nil, wire.Errf(wire.CodeBadRequest, "只有变基、拣选和还原可以跳过")
		}
		if a.Action == "continue" && op == "merge" {
			// "merge --continue" is "commit" with the prepared message
			args = []string{"commit", "--no-edit"}
		} else {
			args = []string{op, "--" + a.Action}
		}
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	out, stderr, err := g.run(ctx, nil, args...)
	e.Audit.Write("git."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo, "rev": a.Rev, "mode": a.Mode, "ok": err == nil})
	text := strings.TrimSpace(string(out) + "\n" + stderr)
	if err != nil {
		if strings.Contains(text, "CONFLICT") || strings.Contains(text, "could not apply") || strings.Contains(text, "after resolving the conflicts") || strings.Contains(text, "fix conflicts") {
			return map[string]any{"ok": true, "conflicts": true, "operation": operationOf(ctx, g), "output": tailText(text, 3000)}, nil
		}
		if a.Action == "continue" && (strings.Contains(text, "unmerged") || strings.Contains(text, "Unmerged") || strings.Contains(text, "not concluded")) {
			return nil, wire.Errf(wire.CodeConflict, "还有冲突没有解决：解决后暂存（标记为已解决）这些文件，再继续")
		}
		return nil, gitErr(stderr+"\n"+string(out), err)
	}
	return map[string]any{"ok": true, "operation": operationOf(ctx, g), "output": tailText(text, 3000)}, nil
}

func operationOf(ctx context.Context, g *gitCtx) string {
	b, _, err := g.run(ctx, nil, "rev-parse", "--git-path", "MERGE_HEAD", "--git-path", "rebase-merge", "--git-path", "rebase-apply", "--git-path", "CHERRY_PICK_HEAD", "--git-path", "REVERT_HEAD")
	if err != nil {
		return ""
	}
	names := []string{"merge", "rebase", "rebase", "cherry-pick", "revert"}
	for i, p := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if i >= len(names) {
			break
		}
		if !strings.HasPrefix(p, "/") {
			p = g.dir + "/" + p
		}
		if paths.IsFile(p) || isDirPath(p) {
			return names[i]
		}
	}
	return ""
}

// git.branch: create (at a revision), rename, delete.
func (e *Env) gitBranch(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if !validRef(a.Branch) {
		return nil, wire.Errf(wire.CodeBadRequest, "分支名无效")
	}
	var args []string
	switch a.Action {
	case "create":
		// A new branch needs a commit to start from: say so, not git's "Not a valid object name".
		if a.Rev == "" {
			if _, err := gitCall(ctx, g, nil, "rev-parse", "--verify", "-q", "HEAD"); err != nil {
				return nil, wire.Errf(wire.CodeConflict, "还没有提交，先提交一次再创建分支")
			}
		}
		args = []string{"branch", a.Branch}
		if a.Rev != "" {
			args = append(args, a.Rev)
		}
	case "rename":
		if !validRef(a.To) {
			return nil, wire.Errf(wire.CodeBadRequest, "新分支名无效")
		}
		args = []string{"branch", "-m", a.Branch, a.To}
	case "delete":
		flag := "-d"
		if a.Force {
			flag = "-D"
		}
		args = []string{"branch", flag, a.Branch}
	case "upstream":
		if !validRef(a.To) {
			return nil, wire.Errf(wire.CodeBadRequest, "上游分支无效")
		}
		args = []string{"branch", "--set-upstream-to=" + a.To, a.Branch}
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	if _, stderr, err := g.run(ctx, nil, args...); err != nil {
		if strings.Contains(stderr, "not fully merged") {
			return nil, wire.Errf(wire.CodeConflict, "分支「%s」还没有合并，删除会丢失它独有的提交", a.Branch)
		}
		return nil, gitErr(stderr, err)
	}
	e.Audit.Write("git.branch."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo, "branch": a.Branch, "to": a.To})
	return map[string]any{"ok": true}, nil
}

type tag struct {
	Name    string `json:"name"`
	Hash    string `json:"hash"`
	Time    int64  `json:"time"`
	Subject string `json:"subject"`
}

func (e *Env) gitTag(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	switch a.Action {
	case "list":
		out, err := gitCall(ctx, g, nil, "for-each-ref", "--sort=-creatordate", "--count=300", "--format=%(refname:short)%00%(objectname:short)%00%(creatordate:unix)%00%(contents:subject)", "refs/tags")
		if err != nil {
			return nil, err
		}
		list := []tag{}
		for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			f := strings.Split(l, "\x00")
			if len(f) < 4 {
				continue
			}
			t, _ := strconv.ParseInt(f[2], 10, 64)
			list = append(list, tag{Name: f[0], Hash: f[1], Time: t, Subject: f[3]})
		}
		return map[string]any{"tags": list}, nil
	case "create":
		if !validRef(a.Name) {
			return nil, wire.Errf(wire.CodeBadRequest, "标签名无效")
		}
		args := []string{"tag"}
		if m := strings.TrimSpace(a.Message); m != "" {
			args = append(args, "-a", "-m", m)
		}
		args = append(args, a.Name)
		if a.Rev != "" {
			if !validRev(a.Rev) {
				return nil, wire.Errf(wire.CodeBadRequest, "版本无效")
			}
			args = append(args, a.Rev)
		}
		if _, err := gitCall(ctx, g, nil, args...); err != nil {
			return nil, err
		}
	case "delete":
		if !validRef(a.Name) {
			return nil, wire.Errf(wire.CodeBadRequest, "标签名无效")
		}
		if _, err := gitCall(ctx, g, nil, "tag", "-d", a.Name); err != nil {
			return nil, err
		}
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	e.Audit.Write("git.tag."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo, "name": a.Name})
	return map[string]any{"ok": true}, nil
}

func isDirPath(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// gitInit: "初始化仓库" of the source control view, for a folder without one.
// It runs as the folder's owner (gitFor), on the main branch.
func (e *Env) gitInit(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root string `json:"root"`
		Path string `json:"path"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	_, abs, err := e.dirOf(a.Root, a.Path)
	if err != nil {
		return nil, err
	}
	g, err := gitFor(abs, e.Proxy)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(filepath.Join(abs, ".git")); err == nil {
		return nil, wire.Errf(wire.CodeConflict, "这个文件夹已经是 Git 仓库")
	}
	if _, err := gitCall(ctx, g, nil, "init", "-b", "main"); err != nil {
		if _, err2 := gitCall(ctx, g, nil, "init"); err2 != nil {
			return nil, err
		}
	}
	e.Audit.Write("git.init", map[string]any{"root": a.Root, "path": a.Path})
	return map[string]any{"ok": true}, nil
}

// gitNumstat: lines added and removed per changed file, work tree against
// HEAD (staged and not together), for the change lists. Binary files: -1.
func (e *Env) gitNumstat(ctx context.Context, raw json.RawMessage) (any, error) {
	_, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	g.env = append(g.env, "GIT_OPTIONAL_LOCKS=0")
	base := "HEAD"
	if _, _, err := g.run(ctx, nil, "rev-parse", "--verify", "-q", "HEAD"); err != nil {
		base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904" // the empty tree: no commit yet
	}
	cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	out, err := gitCall(cctx, g, nil, "diff", base, "--numstat", "-z", "-M", "--no-ext-diff")
	if err != nil {
		return nil, err
	}
	files := parseNumstat(out)
	// new files are not in the diff: count their lines (small text files)
	if b, _, err := g.run(cctx, nil, "ls-files", "--others", "--exclude-standard", "-z"); err == nil {
		n := 0
		for _, p := range strings.Split(string(b), "\x00") {
			if p == "" || n >= 500 {
				continue
			}
			n++
			files[p] = countLines(filepath.Join(g.dir, p))
		}
	}
	return map[string]any{"files": files}, nil
}

// countLines: [lines, 0] of a regular text file up to 2 MB, [-1, -1] otherwise.
func countLines(p string) [2]int {
	fi, err := os.Lstat(p)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > 2<<20 {
		return [2]int{-1, -1}
	}
	b, err := os.ReadFile(p)
	if err != nil || bytes.IndexByte(b[:min(len(b), 8000)], 0) >= 0 {
		return [2]int{-1, -1}
	}
	n := bytes.Count(b, []byte{'\n'})
	if len(b) > 0 && b[len(b)-1] != '\n' {
		n++
	}
	return [2]int{n, 0}
}

// parseNumstat reads "add\tdel\tpath\0" records; a rename is
// "add\tdel\t\0old\0new\0" and is keyed by the new path.
func parseNumstat(out []byte) map[string][2]int {
	res := map[string][2]int{}
	recs := strings.Split(string(out), "\x00")
	for i := 0; i < len(recs) && len(res) < 5000; i++ {
		f := strings.SplitN(recs[i], "\t", 3)
		if len(f) != 3 {
			continue
		}
		n := [2]int{-1, -1}
		if f[0] != "-" {
			n[0], _ = strconv.Atoi(f[0])
			n[1], _ = strconv.Atoi(f[1])
		}
		path := f[2]
		if path == "" && i+2 < len(recs) {
			path = recs[i+2]
			i += 2
		}
		if path != "" {
			res[path] = n
		}
	}
	return res
}

// gitIgnore: "添加到 .gitignore" from the explorer. Each path becomes an
// anchored pattern (/a/b, folders /a/b/) at the end of the repository's
// .gitignore, which keeps its owner.
func (e *Env) gitIgnore(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if len(a.Paths) == 0 || len(a.Paths) > 200 {
		return nil, wire.Errf(wire.CodeBadRequest, "没有选择文件")
	}
	file := filepath.Join(g.dir, ".gitignore")
	// the agent runs as root: never follow a link someone put there
	if fi, err := os.Lstat(file); err == nil && !fi.Mode().IsRegular() {
		return nil, wire.Errf(wire.CodeConflict, ".gitignore 不是普通文件（可能是链接），没有修改")
	}
	old, _ := os.ReadFile(file)
	have := map[string]bool{}
	for _, l := range strings.Split(string(old), "\n") {
		have[strings.TrimSpace(l)] = true
	}
	var add []string
	for _, p := range a.Paths {
		p = strings.Trim(p, "/")
		if p == "" || !validRepoPath(p) || strings.ContainsAny(p, "\n\r") {
			return nil, wire.Errf(wire.CodeBadRequest, "路径无效")
		}
		pat := "/" + escapeIgnore(p)
		if fi, err := os.Stat(filepath.Join(g.dir, p)); err == nil && fi.IsDir() {
			pat += "/"
		}
		if !have[pat] {
			have[pat] = true
			add = append(add, pat)
		}
	}
	if len(add) == 0 {
		return map[string]any{"added": []string{}}, nil
	}
	text := string(old)
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	text += strings.Join(add, "\n") + "\n"
	if err := writeIgnore(file, []byte(text), g); err != nil {
		return nil, err
	}
	e.Audit.Write("git.ignore", map[string]any{"root": a.Root, "repo": a.Repo, "paths": add})
	return map[string]any{"added": add}, nil
}

// writeIgnore replaces .gitignore through a temporary file and a rename (a
// rename replaces a link instead of writing through it), keeping its mode and
// giving it to the repository's owner.
func writeIgnore(file string, data []byte, g *gitCtx) error {
	mode := os.FileMode(0o644)
	uid, gid := -1, -1
	if fi, err := os.Lstat(file); err == nil {
		mode = fi.Mode().Perm()
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			uid, gid = int(st.Uid), int(st.Gid)
		}
	} else if g.cred != nil {
		uid, gid = int(g.cred.Uid), int(g.cred.Gid)
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), ".gitignore.aurora-*")
	if err != nil {
		return wire.Errf(wire.CodeInternal, "写入 .gitignore 失败：%v", err)
	}
	name := tmp.Name()
	defer os.Remove(name)
	_, err = tmp.Write(data)
	if err2 := tmp.Close(); err == nil {
		err = err2
	}
	if err == nil {
		err = os.Chmod(name, mode)
	}
	if err == nil && uid >= 0 {
		_ = os.Chown(name, uid, gid)
	}
	if err == nil {
		err = os.Rename(name, file)
	}
	if err != nil {
		return wire.Errf(wire.CodeInternal, "写入 .gitignore 失败：%v", err)
	}
	return nil
}

// escapeIgnore makes a file name literal in a .gitignore pattern.
func escapeIgnore(p string) string {
	var b strings.Builder
	for i, c := range p {
		if strings.ContainsRune("*?[\\", c) || (i == 0 && (c == '#' || c == '!')) {
			b.WriteByte('\\')
		}
		b.WriteRune(c)
	}
	s := b.String()
	// trailing spaces are dropped by git unless escaped
	if strings.HasSuffix(s, " ") {
		s = strings.TrimRight(s, " ")
		s += strings.Repeat("\\ ", len(p)-len(strings.TrimRight(p, " ")))
	}
	return s
}

// gitRemote: "添加远程仓库" (a repository with nowhere to push yet).
func (e *Env) gitRemote(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	var x struct {
		URL string `json:"url"`
	}
	_ = json.Unmarshal(raw, &x)
	if a.Name == "" {
		a.Name = "origin"
	}
	if !validRef(a.Name) || strings.Contains(a.Name, "/") {
		return nil, wire.Errf(wire.CodeBadRequest, "远程仓库名无效")
	}
	switch a.Action {
	case "add":
		u := strings.TrimSpace(x.URL)
		if u == "" || len(u) > 2000 || strings.HasPrefix(u, "-") || strings.ContainsAny(u, " \t\r\n\x00") {
			return nil, wire.Errf(wire.CodeBadRequest, "地址无效")
		}
		if _, err := gitCall(ctx, g, nil, "remote", "add", "--", a.Name, u); err != nil {
			return nil, err
		}
	case "remove":
		if _, err := gitCall(ctx, g, nil, "remote", "remove", "--", a.Name); err != nil {
			return nil, err
		}
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	e.Audit.Write("git.remote."+a.Action, map[string]any{"root": a.Root, "repo": a.Repo, "name": a.Name})
	return map[string]any{"ok": true}, nil
}

// gitDiff: the review of a repository's changes as unified diffs: staged
// (HEAD -> index), not staged (index -> work tree) and the new files.
func (e *Env) gitDiff(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	g.env = append(g.env, "GIT_OPTIONAL_LOCKS=0")
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	const limit = 4 << 20
	run := func(cached bool) (string, bool, error) {
		args := []string{"diff", "--no-color", "--no-ext-diff", "-U3", "-M"}
		if cached {
			args = append(args, "--cached")
		}
		args = append(args, "--")
		args = append(args, a.Paths...)
		out, stderr, err := g.run(cctx, nil, args...)
		if err != nil {
			return "", false, gitErr(stderr, err)
		}
		if len(out) > limit {
			return string(out[:limit]), true, nil
		}
		return string(out), false, nil
	}
	staged, t1, err := run(true)
	if err != nil {
		return nil, err
	}
	work, t2, err := run(false)
	if err != nil {
		return nil, err
	}
	type newFile struct {
		Path   string `json:"path"`
		Text   string `json:"text"`
		Binary bool   `json:"binary,omitempty"`
		TooBig bool   `json:"too_big,omitempty"`
	}
	news := []newFile{}
	args := append([]string{"ls-files", "--others", "--exclude-standard", "-z", "--"}, a.Paths...)
	if b, _, err := g.run(cctx, nil, args...); err == nil {
		for _, p := range strings.Split(string(b), "\x00") {
			if p == "" || len(news) >= 200 {
				continue
			}
			nf := newFile{Path: p}
			fi, err := os.Lstat(filepath.Join(g.dir, p))
			switch {
			case err != nil || !fi.Mode().IsRegular():
				nf.Binary = true
			case fi.Size() > 512<<10:
				nf.TooBig = true
			default:
				c, err := os.ReadFile(filepath.Join(g.dir, p))
				if err != nil || bytes.IndexByte(c[:min(len(c), 8000)], 0) >= 0 {
					nf.Binary = true
				} else {
					nf.Text = string(c)
				}
			}
			news = append(news, nf)
		}
	}
	return map[string]any{"staged": staged, "unstaged": work, "untracked": news, "truncated": t1 || t2}, nil
}

// gitApply: a patch the client cut out of git.diff (one hunk, some lines)
// applied to the index (stage, unstage) or reversed in the work tree
// (discard). git apply refuses paths outside the repository and beyond links.
func (e *Env) gitApply(ctx context.Context, raw json.RawMessage) (any, error) {
	a, g, _, err := e.repo(raw)
	if err != nil {
		return nil, err
	}
	if a.Content == nil || *a.Content == "" || len(*a.Content) > 4<<20 {
		return nil, wire.Errf(wire.CodeBadRequest, "补丁无效")
	}
	args := []string{"apply", "--whitespace=nowarn", "--unidiff-zero"}
	switch a.Mode {
	case "stage":
		args = append(args, "--cached")
	case "unstage":
		args = append(args, "--cached", "-R")
	case "discard":
		args = append(args, "-R")
	default:
		return nil, wire.Errf(wire.CodeBadRequest, "未知操作")
	}
	args = append(args, "-")
	if _, stderr, err := g.run(ctx, []byte(*a.Content), args...); err != nil {
		if strings.Contains(stderr, "patch does not apply") || strings.Contains(stderr, "while searching for") {
			return nil, wire.Errf(wire.CodeConflict, "文件已经变了，这一块对不上。刷新后再试。\n%s", tailText(stderr, 1000))
		}
		return nil, gitErr(stderr, err)
	}
	if a.Mode == "discard" {
		e.Audit.Write("git.apply.discard", map[string]any{"root": a.Root, "repo": a.Repo})
	}
	return map[string]any{"ok": true}, nil
}