//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func extensionFile(t *testing.T, base, name, text string) {
	t.Helper()
	path := filepath.Join(base, name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}
func TestExtensionsLayeredInstructionsAndSkillOverride(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	work := filepath.Join(root, "project")
	extensionFile(t, state, "ai/AGENTS.md", "user rules")
	extensionFile(t, root, "AGENTS.md", "root rules")
	extensionFile(t, root, "project/CLAUDE.md", "project rules")
	extensionFile(t, root, "project/docs/style.md", "explicit rules")
	extensionFile(t, root, "project/lib/AGENTS.md", "nested rules")
	for _, base := range []string{root, work} {
		extensionFile(t, base, ".aurora/skills/test/SKILL.md", "---\ndescription: \"Run tests\"\n---\n"+base)
	}
	sources, err := discoverLayeredInstructions(state, root, work, []string{"docs/style.md"})
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) != 4 || sources[0].Text != "user rules" || sources[3].Text != "explicit rules" {
		t.Fatal(sources)
	}
	skills, err := discoverSkills(state, root, work, nil)
	if err != nil || len(skills) != 1 || !strings.Contains(skills[0].Path, filepath.Join("project", ".aurora")) {
		t.Fatal(skills, err)
	}
	disabled, err := discoverSkills(state, root, work, []string{"test"})
	if err != nil || len(disabled) != 0 {
		t.Fatal(disabled, err)
	}
	tc := toolContext{rootPath: root, absWorkdir: work}
	if nested := nestedReadInstructions(tc, filepath.Join(work, "lib", "a.go")); !strings.Contains(nested, "nested rules") || strings.Contains(nested, "root rules") {
		t.Fatal(nested)
	}
	extensionFile(t, root, "project/CLAUDE.md", strings.Repeat("x", 25<<10))
	if _, err := discoverLayeredInstructions(state, root, work, nil); err == nil {
		t.Fatal("oversized instructions accepted")
	}
}
func TestExtensionsConfigTransactionAndConflict(t *testing.T) {
	root := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	cfg := defaultExtensionConfig()
	cfg.Budget.Steps = 3
	result, err := (svc{e}).opExtensions(context.Background(), fixtureJSON(map[string]any{"root": "work", "workdir": "/", "config": cfg}))
	if err != nil {
		t.Fatal(err)
	}
	tag := result.(map[string]any)["etag"]
	if tag == "" {
		t.Fatal("missing version")
	}
	cfg.Budget.Steps = 4
	if _, err := (svc{e}).opExtensions(context.Background(), fixtureJSON(map[string]any{"root": "work", "workdir": "/", "config": cfg})); err == nil {
		t.Fatal("stale config overwritten")
	}
	if _, err := (svc{e}).opExtensions(context.Background(), fixtureJSON(map[string]any{"root": "work", "workdir": "/", "config": cfg, "if_match": tag})); err != nil {
		t.Fatal(err)
	}
	got, _, err := loadExtensionConfig(root)
	if err != nil || got.Budget.Steps != 4 {
		t.Fatal(got, err)
	}
	cfg.Instructions = []string{"../outside"}
	if validateExtensionConfig(cfg) == nil {
		t.Fatal("escaping instructions accepted")
	}
}
func TestRunBudgetReservesConcurrentRequestsAndPricesInclusiveUsage(t *testing.T) {
	cfg := defaultExtensionConfig()
	cfg.Budget.Tokens = 1100
	cfg.Budget.Steps = 2
	cfg.Prices["fixture"] = ModelPrice{Input: 2, Output: 4, CacheRead: 0.5, CacheWrite: 3}
	meter := newRunMeter(cfg)
	req := LLMRequest{Provider: ProviderConfig{Model: "fixture"}, MaxTokens: 1000, Messages: []Message{{Role: "user", Parts: []Part{{Type: "text", Text: "prompt"}}}}}
	finish, err := meter.reserve(&req)
	if err != nil {
		t.Fatal(err)
	}
	concurrent := req
	concurrent.Messages = []Message{{Role: "user", Parts: []Part{{Type: "text", Text: strings.Repeat("large", 1024)}}}}
	if _, err := meter.reserve(&concurrent); err == nil {
		t.Fatal("concurrent token reservation bypassed")
	}
	resp := LLMResponse{Usage: Usage{InputTokens: 100, OutputTokens: 20, CacheReadTokens: 30, CacheWriteTokens: 10, TotalTokens: 120}}
	finish(&resp, false)
	if resp.Usage.Cost != 0.000245 {
		t.Fatal(resp.Usage)
	}
	last := req
	finish, err = meter.reserve(&last)
	if err != nil {
		t.Fatal(err)
	}
	finish(&LLMResponse{}, true)
	if _, err := meter.reserve(&req); err == nil {
		t.Fatal("step budget reset")
	}
	cfg.Budget.Cost = 0.01
	cfg.Prices = nil
	if _, err := newRunMeter(cfg).reserve(&req); err == nil {
		t.Fatal("cost budget accepted unknown pricing")
	}
}
func TestSkillDeclarationAndExecutionUsesSameCatalog(t *testing.T) {
	tc := harnessContext(t)
	extensionFile(t, tc.absWorkdir, ".aurora/skills/check/SKILL.md", "---\ndescription: Checks\n---\nUse tests")
	r, err := tc.env.loadExtensions(context.Background(), tc.rootPath, tc.absWorkdir, ProviderConfig{})
	if err != nil {
		t.Fatal(err)
	}
	defer r.close()
	tc.extensions = r
	result := executeTool(context.Background(), tc, "skill", json.RawMessage(`{"name":"check"}`))
	if result.IsError || !strings.Contains(result.Output, "Use tests") {
		t.Fatal(result)
	}
	result = executeTool(context.Background(), tc, "skill", json.RawMessage(`{"name":"missing"}`))
	if !result.IsError {
		t.Fatal("unknown skill accepted")
	}
	tc.provider.Capabilities = map[string]bool{"skill": false}
	result = executeTool(context.Background(), tc, "skill", json.RawMessage(`{"name":"check"}`))
	if !result.IsError {
		t.Fatal("disabled skill exposed")
	}
}
