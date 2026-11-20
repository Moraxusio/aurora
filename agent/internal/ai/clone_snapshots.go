//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"unicode/utf8"

	"aurora3/internal/filetxn"
	"aurora3/internal/paths"
	"aurora3/internal/statecrypt"
)

// CloneWorkspaces maps legacy project roots to their locations in the clone.
// Windows uses the same logical drives; isolated Linux uses fixture paths.
type CloneWorkspaces struct {
	Legacy, Target []Root
	Final          string
}

type snapshotImport struct {
	ctx          context.Context
	source       *SnapshotManager
	stage, final string
	codec        *statecrypt.Codec
	workspaces   CloneWorkspaces
	repos        map[string]bool
	objects      map[string]map[string]string
	writers      map[string]func(string, []byte, int64) (string, error)
}

var gitObject = regexp.MustCompile(`^(?:[a-f0-9]{40}|[a-f0-9]{64})$`)

func (m *snapshotImport) migrate(s *Session) error {
	_, _, sourceWork, err := (&Env{Roots: m.workspaces.Legacy}).resolveWorkspace(s.Root, s.Workdir)
	if err != nil {
		return errors.New("无法定位旧快照对应的工作区")
	}
	targetWork := sourceWork
	if m.workspaces.Target != nil {
		var root *Root
		for i := range m.workspaces.Target {
			if m.workspaces.Target[i].ID == s.Root || (s.Root == "" && i == 0) {
				root = &m.workspaces.Target[i]
				break
			}
		}
		rel, err := paths.Clean(s.Workdir)
		if root == nil || err != nil {
			return errors.New("无法映射快照到验收工作区")
		}
		targetWork = filepath.Join(root.Path, filepath.FromSlash(rel))
		inside, err := filepath.Rel(m.final, targetWork)
		if err != nil || inside == "." || !filepath.IsLocal(inside) {
			return errors.New("快照验收工作区超出克隆目录")
		}
		if err := os.MkdirAll(filepath.Join(m.stage, inside), 0o700); err != nil {
			return err
		}
	}
	repo := m.source.shadowGitDir(sourceWork)
	if !m.repos[repo] {
		if err := checkShadowRepo(repo); err != nil {
			return err
		}
		m.repos[repo] = true
	}
	dest := newProtectedSnapshots(filepath.Join(m.stage, "ai", "snapshots"), targetWork, m.codec)
	put := m.writers[dest.dir]
	if put == nil {
		put, err = dest.writer(snapshotStoreMax)
		if err != nil {
			return err
		}
		m.writers[dest.dir] = put
	}
	scope := repo + "\x00" + dest.dir
	cache := m.objects[scope]
	if cache == nil {
		cache = map[string]string{}
		m.objects[scope] = cache
	}
	for _, message := range s.Messages {
		if message.Snapshot == nil {
			continue
		}
		for _, field := range []*string{&message.Snapshot.Start, &message.Snapshot.End} {
			if *field == "" {
				continue
			}
			if id := cache[*field]; id != "" {
				*field = id
				continue
			}
			id, err := m.importTree(repo, *field, put)
			if err != nil {
				return err
			}
			cache[*field] = id
			*field = id
		}
	}
	return nil
}

func checkShadowRepo(repo string) error {
	root, err := statecrypt.OpenStateDir(repo)
	if err != nil {
		return fmt.Errorf("旧快照仓库无法读取：%w", err)
	}
	defer root.Close()
	for _, file := range []string{"commondir", "objects/info/alternates", "objects/info/http-alternates"} {
		if _, err := root.Lstat(filepath.FromSlash(file)); !os.IsNotExist(err) {
			return errors.New("旧快照仓库依赖外部对象库，未迁移")
		}
	}
	// No links, special files, externally fetched objects, or oversized
	// repositories. No Git command in the importer writes to this tree.
	count := 0
	return filepath.WalkDir(repo, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		count++
		if count > 2*snapshotFilesMax || (!entry.IsDir() && (!entry.Type().IsRegular() || strings.HasSuffix(path, ".promisor"))) {
			return errors.New("旧快照仓库包含不支持的记录")
		}
		if entry.IsDir() && runtime.GOOS == "windows" {
			dir, err := statecrypt.OpenStateDir(path)
			if err != nil {
				return err
			}
			dir.Close()
		}
		return nil
	})
}

func (m *snapshotImport) git(repo string, limit int, args ...string) ([]byte, error) {
	argv := append([]string{"--no-optional-locks", "--no-replace-objects", "--git-dir=" + repo}, args...)
	cmd := quietCommandContext(m.ctx, "git", argv...)
	cmd.Dir = m.stage
	for _, value := range os.Environ() {
		name, _, _ := strings.Cut(value, "=")
		if !strings.HasPrefix(strings.ToUpper(name), "GIT_") {
			cmd.Env = append(cmd.Env, value)
		}
	}
	cmd.Env = append(cmd.Env, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL="+os.DevNull,
		"GIT_NO_LAZY_FETCH=1", "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	out, stderr := newSnapshotBuffer(limit), newSnapshotBuffer(4096)
	cmd.Stdout, cmd.Stderr = out, stderr
	if err := cmd.Run(); err != nil || out.truncated {
		return nil, errors.New("旧快照对象缺失、不可读取或超出迁移预算")
	}
	return out.Bytes(), nil
}

func (m *snapshotImport) importTree(repo, tree string, put func(string, []byte, int64) (string, error)) (string, error) {
	if !gitObject.MatchString(tree) {
		return "", errors.New("旧快照 ID 格式无效")
	}
	listing, err := m.git(repo, 32<<20, "ls-tree", "-rz", "--full-tree", tree+"^{tree}")
	if err != nil {
		return "", err
	}
	if len(listing) != 0 && listing[len(listing)-1] != 0 {
		return "", errors.New("旧快照清单不完整")
	}
	manifest := map[string]protectedFile{}
	seen := map[string]bool{}
	var total int
	for len(listing) > 0 {
		var line []byte
		line, listing, _ = bytes.Cut(listing, []byte{0})
		meta, name, ok := strings.Cut(string(line), "\t")
		fields := strings.Fields(meta)
		rel, err := paths.Clean(name)
		normalized := name
		if runtime.GOOS == "windows" {
			normalized = strings.ToLower(name)
		}
		if !ok || err != nil || name == "." || rel != name || !utf8.ValidString(name) ||
			seen[normalized] || len(manifest) >= snapshotFilesMax || len(fields) != 3 ||
			fields[1] != "blob" || (fields[0] != "100644" && fields[0] != "100755") || !gitObject.MatchString(fields[2]) {
			return "", errors.New("旧快照包含无法安全迁移的路径或文件类型")
		}
		seen[normalized] = true
		data, err := m.git(repo, filetxn.MaxFileBytes, "cat-file", "blob", fields[2])
		if err != nil {
			return "", err
		}
		total += len(data)
		if total > snapshotTreeMax {
			clear(data)
			return "", errors.New("旧快照超过单树导入限额")
		}
		id, err := put("blob", data, filetxn.MaxFileBytes)
		clear(data)
		if err != nil {
			return "", err
		}
		manifest[name] = protectedFile{Blob: id, Exec: fields[0] == "100755"}
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		return "", err
	}
	defer clear(data)
	return put("tree", data, protectedTreeMax)
}
