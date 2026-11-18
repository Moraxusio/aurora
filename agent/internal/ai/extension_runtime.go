//go:build linux || windows

package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"aurora3/internal/mcp"
	"aurora3/internal/paths"
)

type remoteTool struct {
	client               *mcp.Client
	server, name, method string
	readonly             bool
}
type extensionRuntime struct {
	config       ExtensionConfig
	instructions []InstructionSource
	skills       []SkillEntry
	clients      []*mcp.Client
	tools        []ToolDef
	remote       map[string]remoteTool
}

func (e *Env) loadExtensions(ctx context.Context, root, work string, provider ProviderConfig, admitted ...ExtensionConfig) (*extensionRuntime, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var cfg ExtensionConfig
	var err error
	if len(admitted) > 0 {
		cfg = admitted[0]
	} else {
		cfg, _, err = loadExtensionConfig(work)
		if err != nil {
			return nil, err
		}
	}
	r := &extensionRuntime{config: cfg, remote: map[string]remoteTool{}}
	r.instructions, err = discoverLayeredInstructions(e.StateDir, root, work, cfg.Instructions)
	if err != nil {
		return nil, err
	}
	r.skills, err = discoverSkills(e.StateDir, root, work, cfg.DisabledSkills)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			r.close()
		}
	}()
	if provider.allows("tool_calling") && provider.allows("mcp") {
		for _, server := range cfg.MCP {
			if server.Disabled {
				continue
			}
			client, err := mcp.Connect(ctx, server, work)
			if err != nil {
				return nil, fmt.Errorf("MCP %s: %w", server.ID, err)
			}
			r.clients = append(r.clients, client)
			cat, err := client.Catalog(ctx)
			if err != nil {
				return nil, fmt.Errorf("MCP %s: %w", server.ID, err)
			}
			add := func(name, description, method string, params map[string]any, readonly bool) {
				sum := sha256.Sum256([]byte(server.ID + "\x00" + method + "\x00" + name))
				key := "mcp_" + hex.EncodeToString(sum[:12])
				r.remote[key] = remoteTool{client: client, server: server.ID, name: name, method: method, readonly: readonly}
				r.tools = append(r.tools, ToolDef{Name: key, Description: "MCP " + server.ID + "/" + name + ": " + description, Parameters: params})
			}
			for _, tool := range cat.Tools {
				add(tool.Name, tool.Description, "tools/call", tool.InputSchema, tool.Annotations["readOnlyHint"] == true)
			}
			if _, exists := cat.Capabilities["resources"]; exists {
				add("read_resource", "Read an MCP resource URI. Resources listed: "+string(mustJSON(cat.Resources)), "resources/read",
					map[string]any{"type": "object", "properties": map[string]any{"uri": map[string]any{"type": "string"}}, "required": []string{"uri"}}, true)
			}
			if _, exists := cat.Capabilities["prompts"]; exists {
				add("get_prompt", "Load an MCP prompt. Available prompts: "+string(mustJSON(cat.Prompts)), "prompts/get",
					map[string]any{"type": "object", "properties": map[string]any{"name": map[string]any{"type": "string"}, "arguments": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "string"}}}, "required": []string{"name"}}, true)
			}
			if len(r.tools) > 64 {
				return nil, errors.New("MCP 总工具数超过 64 项")
			}
		}
	}
	if len(mustJSON(r.tools)) > 128<<10 {
		return nil, errors.New("MCP 工具定义超过 128 KiB")
	}
	ok = true
	return r, nil
}
func mustJSON(value any) []byte { data, _ := json.Marshal(value); return data }
func (r *extensionRuntime) close() {
	for _, client := range r.clients {
		client.Close()
	}
}
func (r *extensionRuntime) definitions(mode string, provider ProviderConfig) []ToolDef {
	if r == nil || !provider.allows("tool_calling") {
		return nil
	}
	var out []ToolDef
	if len(r.skills) > 0 && provider.allows("skill") {
		names := make([]string, len(r.skills))
		descriptions := make([]string, len(r.skills))
		for i, skill := range r.skills {
			names[i] = skill.Name
			descriptions[i] = skill.Name + ": " + skill.Description
		}
		out = append(out, ToolDef{Name: "skill", Description: "Load a skill's full instructions when relevant to the task. Available skills:\n" + strings.Join(descriptions, "\n"),
			Parameters: map[string]any{"type": "object", "properties": map[string]any{"name": map[string]any{"type": "string", "enum": names}}, "required": []string{"name"}}})
	}
	if provider.allows("mcp") {
		for _, tool := range r.tools {
			if (mode == "plan" || mode == "explore") && !r.remote[tool.Name].readonly {
				continue
			}
			out = append(out, tool)
		}
	}
	return out
}
func (r *extensionRuntime) execute(ctx context.Context, name string, input json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	fail := func(err error) ToolExecResult { return ToolExecResult{Output: err.Error(), IsError: true} }
	if name == "skill" {
		var in struct{ Name string }
		_ = json.Unmarshal(input, &in)
		for _, skill := range r.skills {
			if skill.Name != in.Name {
				continue
			}
			if err := checkPerm("read", skill.Path, nil); err != nil {
				return fail(err)
			}
			data, err := boundedProjectFile(skill.base, skill.relative, 64<<10)
			if err != nil {
				return fail(err)
			}
			return ToolExecResult{Output: "Skill " + skill.Name + "\nBase directory: " + filepath.Dir(skill.Path) + "\n\n" + string(data), Metadata: map[string]any{"skill": skill.Name, "path": skill.Path}}
		}
		return fail(errors.New("技能不存在"))
	}
	remote, ok := r.remote[name]
	if !ok {
		return fail(errors.New("MCP 工具不在当前目录中"))
	}
	if err := checkPerm("mcp", remote.server+"/"+remote.name, map[string]any{"server": remote.server, "tool": remote.name}); err != nil {
		return fail(err)
	}
	var args any
	if err := json.Unmarshal(input, &args); err != nil {
		return fail(err)
	}
	if remote.method == "tools/call" {
		args = map[string]any{"name": remote.name, "arguments": args}
	}
	result, err := remote.client.Call(ctx, remote.method, args)
	if err != nil {
		return fail(err)
	}
	var value struct {
		IsError bool `json:"isError"`
	}
	_ = json.Unmarshal(result, &value)
	return ToolExecResult{Output: string(result), IsError: value.IsError, Metadata: map[string]any{"mcp_server": remote.server, "mcp_tool": remote.name}}
}
func nestedReadInstructions(tc toolContext, path string) string {
	dir := filepath.Dir(path)
	if !paths.Within(tc.absWorkdir, dir) || dir == tc.absWorkdir {
		return ""
	}
	sources, err := discoverLayeredInstructions("", tc.rootPath, dir, nil)
	if err != nil {
		return "\nInstruction discovery error: " + err.Error()
	}
	var nested []InstructionSource
	for _, source := range sources {
		parent := filepath.Dir(source.Path)
		if parent != tc.absWorkdir && paths.Within(tc.absWorkdir, parent) {
			nested = append(nested, source)
		}
	}
	if len(nested) == 0 {
		return ""
	}
	return "\n\nApplicable directory instructions:\n" + renderInstructions(nested)
}
