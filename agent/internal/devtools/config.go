// Package devtools runs configured language servers, debug adapters and tasks
// beside the files they operate on, on either a local or a remote agent.
package devtools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"aurora3/internal/devprocess"
	"aurora3/internal/filetxn"
	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

const configPath = ".aurora/development.json"
const configMax = 256 << 10
const maxProcesses = 8

type Root struct{ ID, Path string }
type Auditor interface{ Write(string, map[string]any) }
type Env struct {
	Roots    []Root
	StateDir string
	Audit    Auditor
	Proxy    func() map[string]string
	mu       sync.Mutex
	running  int
}

type Program struct {
	ID      string            `json:"id"`
	Label   string            `json:"label,omitempty"`
	Command []string          `json:"command"`
	Env     map[string]string `json:"env,omitempty"`
	Cwd     string            `json:"cwd,omitempty"` // relative to the configured project
}
type LanguageServer struct {
	Program
	Languages             []string       `json:"languages"`
	InitializationOptions any            `json:"initializationOptions,omitempty"`
	Settings              map[string]any `json:"settings,omitempty"`
}
type Task struct {
	Program
	Group          string   `json:"group,omitempty"` // build | test | lint
	DependsOn      []string `json:"dependsOn,omitempty"`
	TimeoutSeconds int      `json:"timeoutSeconds,omitempty"`
	ProblemPattern string   `json:"problemPattern,omitempty"` // file:line:column: message by default
	TestFormat     string   `json:"testFormat,omitempty"`     // go-json | tap
}
type DebugAdapter struct {
	Program
	Request       string         `json:"request"` // launch | attach
	Arguments     map[string]any `json:"arguments"`
	PreLaunchTask string         `json:"preLaunchTask,omitempty"`
}
type Config struct {
	Version         int              `json:"version"`
	LanguageServers []LanguageServer `json:"languageServers"`
	Tasks           []Task           `json:"tasks"`
	Debug           []DebugAdapter   `json:"debug"`
}
type scopeArgs struct {
	Root    string  `json:"root"`
	Path    string  `json:"path"`
	ID      string  `json:"id"`
	IfMatch string  `json:"if_match"`
	Config  *Config `json:"config"`
}

func fileURI(path string) string {
	p := filepath.ToSlash(path)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return (&url.URL{Scheme: "file", Path: p}).String()
}

func (e *Env) scope(a scopeArgs) (rootPath, work string, err error) {
	for _, root := range e.Roots {
		if root.ID != a.Root {
			continue
		}
		rootPath, err = filepath.EvalSymlinks(root.Path)
		if err != nil {
			return "", "", err
		}
		work, err = paths.Resolve(rootPath, a.Path)
		if err != nil {
			return "", "", paths.WireError(err)
		}
		info, err := os.Stat(work)
		if err != nil {
			return "", "", err
		}
		if !info.IsDir() {
			return "", "", wire.Errf(wire.CodeBadRequest, "开发工作目录必须是文件夹")
		}
		return rootPath, work, nil
	}
	return "", "", wire.Errf(wire.CodeNotFound, "工作根目录不存在")
}

func decodeScope(raw json.RawMessage) (scopeArgs, error) {
	var a scopeArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return a, wire.Errf(wire.CodeBadRequest, "开发配置请求无效")
	}
	return a, nil
}

func readConfig(work string) (Config, filetxn.State, error) {
	cfg := Config{Version: 1, LanguageServers: []LanguageServer{}, Tasks: []Task{}, Debug: []DebugAdapter{}}
	state := filetxn.State{UID: -1, GID: -1}
	root, err := os.OpenRoot(work)
	if err != nil {
		return cfg, state, err
	}
	defer root.Close()
	f, err := root.Open(configPath)
	if os.IsNotExist(err) {
		return cfg, state, nil
	}
	if err != nil {
		return cfg, state, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return cfg, state, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > configMax {
		return cfg, state, errors.New("开发配置超过 256 KiB 或不是普通文件")
	}
	data, err := io.ReadAll(io.LimitReader(f, configMax+1))
	if err != nil {
		return cfg, state, err
	}
	if len(data) > configMax {
		return cfg, state, errors.New("开发配置超过 256 KiB")
	}
	state.Exists, state.Data, state.Mode = true, data, fi.Mode().Perm()
	if err = json.Unmarshal(data, &cfg); err != nil {
		return cfg, state, fmt.Errorf("开发配置 JSON 无效: %w", err)
	}
	return cfg, state, cfg.validate()
}

func configTag(state filetxn.State) string {
	if !state.Exists {
		return "missing"
	}
	sum := sha256.Sum256(state.Data)
	return hex.EncodeToString(sum[:])
}

func (cfg Config) validate() error {
	if cfg.Version != 1 {
		return errors.New("开发配置 version 必须为 1")
	}
	if len(cfg.LanguageServers) > 16 || len(cfg.Tasks) > 128 || len(cfg.Debug) > 32 {
		return errors.New("开发配置条目超过上限")
	}
	check := func(p Program, seen map[string]bool) error {
		if p.ID == "" || len(p.ID) > 128 || seen[p.ID] {
			return fmt.Errorf("无效或重复的开发工具 ID: %s", p.ID)
		}
		seen[p.ID] = true
		if len(p.Command) == 0 || len(p.Command) > 128 || p.Command[0] == "" {
			return fmt.Errorf("%s: command 必须是非空参数数组", p.ID)
		}
		for _, s := range p.Command {
			if len(s) > 32768 || strings.ContainsRune(s, 0) {
				return errors.New("命令参数无效")
			}
		}
		if p.Cwd != "" && p.Cwd != "." && !filepath.IsLocal(filepath.FromSlash(p.Cwd)) {
			return errors.New("cwd 必须位于项目内")
		}
		if len(p.Env) > 128 {
			return errors.New("环境变量过多")
		}
		for key, value := range p.Env {
			if key == "" || strings.ContainsAny(key, "=\x00") || strings.ContainsRune(value, 0) {
				return errors.New("环境变量格式无效")
			}
		}
		return nil
	}
	seen := map[string]bool{}
	for _, s := range cfg.LanguageServers {
		if err := check(s.Program, seen); err != nil {
			return err
		}
		if len(s.Languages) == 0 {
			return fmt.Errorf("%s 缺少 languages", s.ID)
		}
	}
	seen = map[string]bool{}
	tasks := map[string]Task{}
	for _, t := range cfg.Tasks {
		if err := check(t.Program, seen); err != nil {
			return err
		}
		if t.TimeoutSeconds < 0 || t.TimeoutSeconds > 86400 {
			return errors.New("任务超时须在 0–86400 秒之间")
		}
		if _, err := problemMatcher(t.ProblemPattern); err != nil {
			return fmt.Errorf("%s 问题匹配器: %w", t.ID, err)
		}
		tasks[t.ID] = t
	}
	visiting, done := map[string]bool{}, map[string]bool{}
	var visit func(string) error
	visit = func(id string) error {
		task, ok := tasks[id]
		if !ok {
			return fmt.Errorf("任务依赖不存在: %s", id)
		}
		if visiting[id] {
			return fmt.Errorf("任务依赖循环: %s", id)
		}
		if done[id] {
			return nil
		}
		visiting[id] = true
		for _, dep := range task.DependsOn {
			if err := visit(dep); err != nil {
				return err
			}
		}
		delete(visiting, id)
		done[id] = true
		return nil
	}
	for id := range tasks {
		if err := visit(id); err != nil {
			return err
		}
	}
	seen = map[string]bool{}
	for _, d := range cfg.Debug {
		if err := check(d.Program, seen); err != nil {
			return err
		}
		if d.Request != "launch" && d.Request != "attach" {
			return errors.New("调试 request 必须为 launch 或 attach")
		}
		if d.PreLaunchTask != "" {
			if _, ok := tasks[d.PreLaunchTask]; !ok {
				return errors.New("调试前置任务不存在")
			}
		}
	}
	return nil
}

func (e *Env) configuration(ctx context.Context, raw json.RawMessage) (any, error) {
	a, err := decodeScope(raw)
	if err != nil {
		return nil, err
	}
	rootPath, work, err := e.scope(a)
	if err != nil {
		return nil, err
	}
	cfg, state, err := readConfig(work)
	if err != nil {
		return nil, err
	}
	return map[string]any{"config": cfg, "etag": configTag(state), "rootUri": fileURI(rootPath),
		"workspaceUri": fileURI(work), "platform": runtime.GOOS, "processLimit": maxProcesses}, nil
}

func (e *Env) configure(ctx context.Context, raw json.RawMessage) (any, error) {
	a, err := decodeScope(raw)
	if err != nil {
		return nil, err
	}
	if a.Config == nil {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少 config")
	}
	if err := a.Config.validate(); err != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	rootPath, work, err := e.scope(a)
	if err != nil {
		return nil, err
	}
	_, before, err := readConfig(work)
	if err != nil {
		return nil, err
	}
	if configTag(before) != a.IfMatch {
		return nil, wire.Errf(wire.CodeConflict, "开发配置已被修改，请重新读取")
	}
	data, err := json.MarshalIndent(a.Config, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(data) > configMax {
		return nil, wire.Errf(wire.CodeBadRequest, "开发配置超过 256 KiB")
	}
	after := filetxn.State{Exists: true, Data: append(data, '\n'), Mode: 0o600}
	if err := filetxn.New(e.StateDir, []string{rootPath}).Commit(ctx, []filetxn.Change{
		{Root: work, Path: filepath.FromSlash(configPath), Before: before, After: after},
	}); err != nil {
		return nil, err
	}
	if e.Audit != nil {
		e.Audit.Write("devtools.configure", map[string]any{"root": a.Root, "path": a.Path})
	}
	return map[string]any{"etag": configTag(after)}, nil
}

func (e *Env) environment(extra map[string]string) []string {
	merged := map[string]string{}
	for _, value := range os.Environ() {
		key, val, ok := strings.Cut(value, "=")
		if ok {
			if runtime.GOOS == "windows" {
				key = strings.ToUpper(key)
			}
			merged[key] = val
		}
	}
	add := func(values map[string]string) {
		for key, value := range values {
			if runtime.GOOS == "windows" {
				key = strings.ToUpper(key)
			}
			merged[key] = value
		}
	}
	if e.Proxy != nil {
		add(e.Proxy())
	}
	add(extra)
	out := make([]string, 0, len(merged))
	for key, value := range merged {
		out = append(out, key+"="+value)
	}
	return out
}

func (e *Env) acquire() (func(), error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.running >= maxProcesses {
		return nil, wire.Errf(wire.CodeUnavailable, "开发进程已达到 %d 个并发上限", maxProcesses)
	}
	release, err := devprocess.Reserve()
	if err != nil {
		return nil, err
	}
	e.running++
	return func() { e.mu.Lock(); e.running--; e.mu.Unlock(); release() }, nil
}
