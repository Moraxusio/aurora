//go:build linux || windows

package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"aurora3/internal/filetxn"
	"aurora3/internal/mcp"
	"aurora3/internal/paths"
)

const extensionConfigPath = ".aurora/ai.json"
const extensionConfigMax = 128 << 10

type RunBudget struct {
	// Missing fields inherit defaults when loading a project; explicit zero
	// disables that limit. Do not omit zeros when saving.
	Steps       int     `json:"steps"`
	Seconds     int     `json:"seconds"`
	Tokens      int     `json:"tokens"`
	Cost        float64 `json:"cost"`
	OutputBytes int     `json:"outputBytes"`
}
type ModelPrice struct {
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheRead  float64 `json:"cacheRead"`
	CacheWrite float64 `json:"cacheWrite"`
}
type ExtensionConfig struct {
	Version        int                   `json:"version"`
	Instructions   []string              `json:"instructions"`
	DisabledSkills []string              `json:"disabledSkills"`
	MCP            []mcp.Config          `json:"mcp"`
	Budget         RunBudget             `json:"budget"`
	BudgetEnabled  *bool                 `json:"budgetEnabled,omitempty"`
	Subagents      *SubagentOptions      `json:"subagents,omitempty"`
	Tools          *ToolOptions          `json:"tools,omitempty"`
	Prices         map[string]ModelPrice `json:"prices"` // per million tokens, keyed by model ID
	AutoTitle      *bool                 `json:"autoTitle,omitempty"`
	AutoCompact    *bool                 `json:"autoCompact,omitempty"`
	Snapshots      *bool                 `json:"snapshots,omitempty"`
	Snapshot       *SnapshotOptions      `json:"snapshot,omitempty"`
}

func defaultExtensionConfig() ExtensionConfig {
	return ExtensionConfig{Version: 1, Instructions: []string{}, DisabledSkills: []string{}, MCP: []mcp.Config{},
		Budget: RunBudget{Steps: 60, Seconds: 900, Tokens: 500000, OutputBytes: 2 << 20}, Prices: map[string]ModelPrice{}}
}

func (c *ExtensionConfig) UnmarshalJSON(data []byte) error {
	type plain ExtensionConfig
	value := plain(defaultExtensionConfig())
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*c = ExtensionConfig(value)
	return nil
}
func boundedProjectFile(base, relative string, max int64) ([]byte, error) {
	root, err := os.OpenRoot(base)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.Open(relative)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > max {
		return nil, errors.New("文件不是普通文件或超过读取预算")
	}
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err == nil && (int64(len(data)) > max || !utf8.Valid(data)) {
		err = errors.New("文件超过读取预算或不是 UTF-8")
	}
	return data, err
}
func loadExtensionConfig(work string) (ExtensionConfig, string, error) {
	cfg := defaultExtensionConfig()
	b, err := boundedProjectFile(work, extensionConfigPath, extensionConfigMax)
	if os.IsNotExist(err) {
		return cfg, "", nil
	}
	if err != nil {
		return cfg, "", err
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return cfg, "", fmt.Errorf("%s: %w", extensionConfigPath, err)
	}
	if err := validateExtensionConfig(cfg); err != nil {
		return cfg, "", err
	}
	sum := sha256.Sum256(b)
	return cfg, hex.EncodeToString(sum[:]), nil
}
func validateExtensionConfig(cfg ExtensionConfig) error {
	children, tools := cfg.Subagents.resolved(), cfg.Tools.resolved()
	if children.MaxParallel < 1 || children.MaxParallel > 16 || children.MaxTotal < 0 || children.MaxTotal > 1000 {
		return errors.New("子代理并发数须为 1–16，单次任务总量须为 0–1000（0 不限）")
	}
	if tools.MaxCallsPerStep < 1 || tools.MaxCallsPerStep > 64 || tools.RepeatLimit < 0 || tools.RepeatLimit > 20 ||
		tools.ShellDefaultSeconds < 1 || tools.ShellMaxSeconds > 600 || tools.ShellMaxSeconds < tools.ShellDefaultSeconds {
		return errors.New("工具策略范围：每步 1–64 次，重复检测 0–20 次，Shell 默认／最大超时 1–600 秒")
	}
	if err := cfg.Snapshot.validate(); err != nil {
		return err
	}
	b := cfg.Budget
	if cfg.Version != 1 || len(cfg.Instructions) > 32 || len(cfg.DisabledSkills) > 64 || len(cfg.MCP) > 4 ||
		b.Steps < 0 || b.Steps > 10000 || b.Seconds < 0 || b.Seconds > 604800 || b.Tokens < 0 || b.Tokens > 1000000000 ||
		b.Cost < 0 || b.Cost > 1000000 || math.IsNaN(b.Cost) || b.OutputBytes < 0 || b.OutputBytes > 1<<30 || len(cfg.Prices) > 64 {
		return errors.New("AI 配置版本、条目或运行预算超出范围")
	}
	for _, p := range cfg.Instructions {
		if !filepath.IsLocal(filepath.FromSlash(p)) {
			return errors.New("指令文件须是项目内相对路径")
		}
	}
	seen := map[string]bool{}
	for _, c := range cfg.MCP {
		if seen[c.ID] {
			return errors.New("MCP 标识重复")
		}
		if err := c.Validate(); err != nil {
			return err
		}
		seen[c.ID] = true
	}
	for _, p := range cfg.Prices {
		for _, value := range []float64{p.Input, p.Output, p.CacheRead, p.CacheWrite} {
			if value < 0 || value > 100000 || math.IsNaN(value) {
				return errors.New("模型价格须在 0–100000 USD／百万 tokens 之间")
			}
		}
	}
	return nil
}

func enabledByDefault(value *bool) bool { return value == nil || *value }

type InstructionSource struct {
	Path string `json:"path"`
	Text string `json:"text"`
}
type SkillEntry struct {
	Name           string `json:"name"`
	Description    string `json:"description"`
	Path           string `json:"path"`
	base, relative string
}

var extensionID = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

// Walk only the configured root's ancestor chain. Reading a deeper file later
// attaches that directory's more specific instructions to the read result.
func instructionDirectories(root, work string) []string {
	var dirs []string
	for p := filepath.Clean(work); paths.Within(root, p); p = filepath.Dir(p) {
		dirs = append(dirs, p)
		if p == filepath.Clean(root) || filepath.Dir(p) == p {
			break
		}
	}
	for i, j := 0, len(dirs)-1; i < j; i, j = i+1, j-1 {
		dirs[i], dirs[j] = dirs[j], dirs[i]
	}
	return dirs
}
func discoverLayeredInstructions(stateDir, root, work string, extra []string) ([]InstructionSource, error) {
	var sources []InstructionSource
	total := 0
	add := func(base, rel string) error {
		data, err := boundedProjectFile(base, rel, 24<<10)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", filepath.Join(base, rel), err)
		}
		if len(data) == 0 {
			return nil
		}
		total += len(data)
		if total > 96<<10 {
			return errors.New("分层指令超过 96 KiB")
		}
		sources = append(sources, InstructionSource{filepath.Join(base, rel), string(data)})
		return nil
	}
	if stateDir != "" {
		if err := add(filepath.Join(stateDir, "ai"), "AGENTS.md"); err != nil {
			return nil, err
		}
	}
	for _, dir := range instructionDirectories(root, work) {
		rel, _ := filepath.Rel(root, dir)
		for _, name := range []string{"AGENTS.md", "CLAUDE.md", ".cursorrules"} {
			before := len(sources)
			if err := add(root, filepath.Join(rel, name)); err != nil {
				return nil, err
			}
			if len(sources) > before {
				break
			}
		}
	}
	for _, name := range extra {
		if err := add(work, name); err != nil {
			return nil, err
		}
	}
	return sources, nil
}
func renderInstructions(sources []InstructionSource) string {
	var out strings.Builder
	for _, source := range sources {
		fmt.Fprintf(&out, "Instructions from %s:\n%s\n\n", source.Path, source.Text)
	}
	return out.String()
}
func discoverSkills(stateDir, root, work string, disabled []string) ([]SkillEntry, error) {
	found := map[string]SkillEntry{}
	add := func(base, relative string) error {
		r, err := os.OpenRoot(base)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		defer r.Close()
		f, err := r.Open(relative)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		defer f.Close()
		entries, err := f.ReadDir(129)
		if err != nil && err != io.EOF {
			return err
		}
		if len(entries) > 128 {
			return errors.New("技能目录超过 128 项")
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, entry := range entries {
			if !entry.IsDir() || !extensionID.MatchString(entry.Name()) {
				continue
			}
			rel := filepath.Join(relative, entry.Name(), "SKILL.md")
			data, err := boundedProjectFile(base, rel, 64<<10)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return fmt.Errorf("skill %s: %w", entry.Name(), err)
			}
			text := strings.ReplaceAll(string(data), "\r\n", "\n")
			description := ""
			if strings.HasPrefix(text, "---\n") {
				if end := strings.Index(text[4:], "\n---"); end >= 0 {
					for _, line := range strings.Split(text[4:4+end], "\n") {
						if value, ok := strings.CutPrefix(line, "description:"); ok {
							description = strings.Trim(strings.TrimSpace(value), `"'`)
						}
					}
				}
			}
			if description == "" {
				description = "Load instructions for " + entry.Name()
			}
			found[entry.Name()] = SkillEntry{Name: entry.Name(), Description: truncateShort(description, 512), Path: filepath.Join(base, rel), base: base, relative: rel}
			if len(found) > 64 {
				return errors.New("可用技能超过 64 项")
			}
		}
		return nil
	}
	if stateDir != "" {
		if err := add(filepath.Join(stateDir, "ai"), "skills"); err != nil {
			return nil, err
		}
	}
	for _, dir := range instructionDirectories(root, work) {
		rel, _ := filepath.Rel(root, dir)
		for _, name := range []string{".opencode/skills", ".agents/skills", ".aurora/skills"} {
			if err := add(root, filepath.Join(rel, filepath.FromSlash(name))); err != nil {
				return nil, err
			}
		}
	}
	for _, name := range disabled {
		delete(found, name)
	}
	var out []SkillEntry
	for _, entry := range found {
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func (s svc) opExtensions(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		Root, Workdir string
		Config        *ExtensionConfig `json:"config"`
		IfMatch       string           `json:"if_match"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	rt, _, work, err := s.resolveWorkspace(in.Root, in.Workdir)
	if err != nil {
		return nil, err
	}
	if in.Config != nil {
		if err := validateExtensionConfig(*in.Config); err != nil {
			return nil, err
		}
		data, err := json.MarshalIndent(in.Config, "", "  ")
		if err != nil || len(data) > extensionConfigMax {
			return nil, errors.New("AI 配置超过 128 KiB")
		}
		filetxn.CommitMu.Lock()
		err = func() error {
			root, err := os.OpenRoot(work)
			if err != nil {
				return err
			}
			defer root.Close()
			before, err := filetxn.Read(root, extensionConfigPath)
			if err != nil {
				return err
			}
			tag := ""
			if before.Exists {
				sum := sha256.Sum256(before.Data)
				tag = hex.EncodeToString(sum[:])
			}
			if tag != in.IfMatch {
				return errors.New("AI 配置已变化，请重新读取")
			}
			after := filetxn.State{Exists: true, Data: append(data, '\n'), Mode: 0600, UID: -1, GID: -1}
			return filetxn.New(s.StateDir, []string{work}).CommitLocked(ctx, []filetxn.Change{{Root: work, Path: filepath.FromSlash(extensionConfigPath), Before: before, After: after}})
		}()
		filetxn.CommitMu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	cfg, tag, err := loadExtensionConfig(work)
	if err != nil {
		return nil, err
	}
	sources, err := discoverLayeredInstructions(s.StateDir, rt.Path, work, cfg.Instructions)
	if err != nil {
		return nil, err
	}
	skills, err := discoverSkills(s.StateDir, rt.Path, work, cfg.DisabledSkills)
	if err != nil {
		return nil, err
	}
	allSkills, err := discoverSkills(s.StateDir, rt.Path, work, nil)
	if err != nil {
		return nil, err
	}
	source := "project"
	if tag == "" {
		source = "default"
	}
	return map[string]any{"config": cfg, "etag": tag, "source": source,
		"defaults": defaultExtensionConfig(), "budget_version": 2,
		"controls_version": 1, "subagent_defaults": defaultSubagentOptions(), "tool_defaults": defaultToolOptions(), "nested_subagents": false,
		"snapshot_defaults": defaultSnapshotOptions(),
		"instructions":      sources, "skills": skills, "available_skills": allSkills}, nil
}

func (s svc) opMCPProbe(ctx context.Context, raw json.RawMessage) (any, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var in struct{ Root, Workdir, ID string }
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	_, _, work, err := s.resolveWorkspace(in.Root, in.Workdir)
	if err != nil {
		return nil, err
	}
	cfg, _, err := loadExtensionConfig(work)
	if err != nil {
		return nil, err
	}
	for _, server := range cfg.MCP {
		if server.ID != in.ID {
			continue
		}
		client, err := mcp.Connect(ctx, server, work)
		if err != nil {
			return nil, err
		}
		defer client.Close()
		catalog, err := client.Catalog(ctx)
		if err != nil {
			return nil, err
		}
		return catalog, nil
	}
	return nil, errors.New("MCP 服务不存在")
}
