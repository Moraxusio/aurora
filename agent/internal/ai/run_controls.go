//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

type SubagentOptions struct {
	Enabled        *bool  `json:"enabled,omitempty"`
	MaxParallel    int    `json:"maxParallel"`
	MaxTotal       int    `json:"maxTotal"`
	ReadOnly       bool   `json:"readOnly"`
	PermissionMode string `json:"permissionMode,omitempty"` // "" | "inherit" | "ask" | "readOnly" | "auto"
	AllowNetwork   *bool  `json:"allowNetwork,omitempty"`
	AllowShell     *bool  `json:"allowShell,omitempty"`
}

func defaultSubagentOptions() SubagentOptions {
	return SubagentOptions{MaxParallel: 1, MaxTotal: 32}
}
func (o *SubagentOptions) UnmarshalJSON(data []byte) error {
	type plain SubagentOptions
	value := plain(defaultSubagentOptions())
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*o = SubagentOptions(value)
	return nil
}
func (o *SubagentOptions) resolved() SubagentOptions {
	if o == nil {
		return defaultSubagentOptions()
	}
	out := *o
	if out.MaxParallel == 0 {
		out.MaxParallel = 1
	}
	return out
}

type ToolOptions struct {
	MaxCallsPerStep     int `json:"maxCallsPerStep"`
	RepeatLimit         int `json:"repeatLimit"`
	ShellDefaultSeconds int `json:"shellDefaultSeconds"`
	ShellMaxSeconds     int `json:"shellMaxSeconds"`
}

func defaultToolOptions() ToolOptions {
	return ToolOptions{MaxCallsPerStep: 64, RepeatLimit: 3, ShellDefaultSeconds: 120, ShellMaxSeconds: 600}
}
func (o *ToolOptions) UnmarshalJSON(data []byte) error {
	type plain ToolOptions
	value := plain(defaultToolOptions())
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*o = ToolOptions(value)
	return nil
}
func (o *ToolOptions) resolved() ToolOptions {
	if o == nil {
		return defaultToolOptions()
	}
	return *o
}

// Options are a conversation/message policy override. Steering is part of the current turn;
// queued messages start their own budget with the configuration admitted here.
type RunOptions struct {
	BudgetMode              string       `json:"budgetMode,omitempty"` // inherit | on | off | custom
	Budget                  *RunBudget   `json:"budget,omitempty"`
	Subagents               *bool        `json:"subagents,omitempty"`
	MaxParallel             int          `json:"maxParallel,omitempty"`
	MaxTotal                *int         `json:"maxTotal,omitempty"`
	SubagentsReadOnly       *bool        `json:"subagentsReadOnly,omitempty"`
	SubagentsPermissionMode string       `json:"subagentsPermissionMode,omitempty"`
	SubagentsAllowNetwork   *bool        `json:"subagentsAllowNetwork,omitempty"`
	SubagentsAllowShell     *bool        `json:"subagentsAllowShell,omitempty"`
	Tools                   *ToolOptions `json:"tools,omitempty"`
	AutoTitle               *bool        `json:"autoTitle,omitempty"`
	AutoCompact             *bool        `json:"autoCompact,omitempty"`
	Snapshots               *bool        `json:"snapshots,omitempty"`
	Instructions            []string     `json:"instructions,omitempty"`
}

func (o *RunOptions) changed() bool {
	return o != nil && (o.BudgetMode != "" && o.BudgetMode != "inherit" ||
		o.Budget != nil || o.Subagents != nil || o.MaxParallel != 0 ||
		o.MaxTotal != nil || o.SubagentsReadOnly != nil ||
		o.SubagentsPermissionMode != "" || o.SubagentsAllowNetwork != nil ||
		o.SubagentsAllowShell != nil || o.Tools != nil ||
		o.AutoTitle != nil || o.AutoCompact != nil || o.Snapshots != nil ||
		len(o.Instructions) > 0)
}
func applyRunOptions(cfg ExtensionConfig, o *RunOptions) (ExtensionConfig, error) {
	if o == nil {
		return cfg, nil
	}
	// Snapshot caller-owned pointers before the background runner uses them.
	data, err := json.Marshal(o)
	if err != nil {
		return cfg, err
	}
	var copy RunOptions
	if err := json.Unmarshal(data, &copy); err != nil {
		return cfg, err
	}
	o = &copy
	if o.Budget != nil && o.BudgetMode != "custom" {
		return cfg, errors.New("自定义预算须选择 custom 模式")
	}
	on, off := true, false
	switch o.BudgetMode {
	case "", "inherit":
		if o.Budget != nil {
			return cfg, errors.New("自定义预算须选择 custom 模式")
		}
	case "on":
		cfg.BudgetEnabled = &on
	case "off":
		cfg.BudgetEnabled = &off
	case "custom":
		if o.Budget == nil {
			return cfg, errors.New("自定义预算缺少限额")
		}
		cfg.Budget, cfg.BudgetEnabled = *o.Budget, &on
	default:
		return cfg, errors.New("未知预算模式")
	}
	if o.MaxParallel < 0 || o.MaxParallel > 16 {
		return cfg, errors.New("子代理并发数须为 1–16；0 继承默认")
	}
	if o.Subagents != nil || o.MaxParallel != 0 || o.MaxTotal != nil ||
		o.SubagentsReadOnly != nil || o.SubagentsPermissionMode != "" ||
		o.SubagentsAllowNetwork != nil || o.SubagentsAllowShell != nil {
		children := cfg.Subagents.resolved()
		if o.Subagents != nil {
			children.Enabled = o.Subagents
		}
		if o.MaxParallel != 0 {
			children.MaxParallel = o.MaxParallel
		}
		if o.MaxTotal != nil {
			children.MaxTotal = *o.MaxTotal
		}
		if o.SubagentsReadOnly != nil {
			children.ReadOnly = *o.SubagentsReadOnly
		}
		if o.SubagentsPermissionMode != "" {
			if o.SubagentsPermissionMode == "inherit" {
				children.PermissionMode = ""
			} else {
				children.PermissionMode = o.SubagentsPermissionMode
			}
		}
		if o.SubagentsAllowNetwork != nil {
			children.AllowNetwork = o.SubagentsAllowNetwork
		}
		if o.SubagentsAllowShell != nil {
			children.AllowShell = o.SubagentsAllowShell
		}
		cfg.Subagents = &children
	}
	if o.Tools != nil {
		t := o.Tools.resolved()
		cfg.Tools = &t
	}
	if o.AutoTitle != nil {
		cfg.AutoTitle = o.AutoTitle
	}
	if o.AutoCompact != nil {
		cfg.AutoCompact = o.AutoCompact
	}
	if o.Snapshots != nil {
		cfg.Snapshots = o.Snapshots
	}
	if len(o.Instructions) > 0 {
		cfg.Instructions = append(cfg.Instructions, o.Instructions...)
	}
	return cfg, validateExtensionConfig(cfg)
}

func (s svc) opRunOptions(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct{ Root, Workdir string }
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	_, _, work, err := s.resolveWorkspace(in.Root, in.Workdir)
	if err != nil {
		return nil, err
	}
	cfg, tag, err := loadExtensionConfig(work)
	if err != nil {
		return nil, err
	}
	source := "project"
	if tag == "" {
		source = "default"
	}
	return map[string]any{
		"source": source, "budget": cfg.Budget, "budgetEnabled": enabledByDefault(cfg.BudgetEnabled),
		"subagents": cfg.Subagents.resolved(), "autoCompact": enabledByDefault(cfg.AutoCompact),
		"snapshots": enabledByDefault(cfg.Snapshots), "nestedSubagents": false,
	}, nil
}

// A shared per-turn limiter is also enforced at child admission, not just at
// the dispatcher. Descendants cannot acquire it, even when manually resumed.
func (m *runMeter) acquireChild(ctx context.Context) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	policy := m.config.Subagents.resolved()
	if !enabledByDefault(policy.Enabled) {
		return nil, errors.New("此任务已禁用子代理")
	}
	select {
	case m.childSlots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		<-m.childSlots
		return nil, err
	}
	m.mu.Lock()
	if policy.MaxTotal > 0 && m.childrenStarted >= policy.MaxTotal {
		m.mu.Unlock()
		<-m.childSlots
		return nil, fmt.Errorf("本次任务的子代理数量已达到 %d；可在项目「代理协作」中调整", policy.MaxTotal)
	}
	m.childrenStarted++
	m.childrenActive++
	m.mu.Unlock()
	m.publish()
	return func() {
		m.mu.Lock()
		m.childrenActive--
		m.mu.Unlock()
		<-m.childSlots
		m.publish()
	}, nil
}

func configuredToolDefinitions(mode string, depth int, provider ProviderConfig, ext *extensionRuntime) []ToolDef {
	defs := modelToolDefinitions(mode, depth, provider)
	if ext == nil {
		return defs
	}
	policy := ext.config.Subagents.resolved()
	out := make([]ToolDef, 0, len(defs))
	for _, def := range defs {
		if def.Name == "subagent" {
			if !enabledByDefault(policy.Enabled) {
				continue
			}
			def.Description += fmt.Sprintf("\nAt most %d child agents may run together; children cannot delegate. Submit independent subagent calls together to run them concurrently.", policy.MaxParallel)
			if policy.ReadOnly {
				def.Description += "\nOnly read-only exploration is allowed by project policy."
				def.Parameters["properties"].(map[string]any)["agent"] = map[string]any{"type": "string", "enum": []string{"explore"}}
			}
		}
		if def.Name == "shell" {
			p := ext.config.Tools.resolved()
			def.Description += fmt.Sprintf("\nProject timeout: default %d seconds, maximum %d seconds.", p.ShellDefaultSeconds, p.ShellMaxSeconds)
			def.Parameters["properties"].(map[string]any)["timeout"] = map[string]any{
				"type": "integer", "minimum": 0,
				"description": fmt.Sprintf("Timeout in milliseconds; omit or use zero for the project default of %d ms. Values above %d ms are capped.", p.ShellDefaultSeconds*1000, p.ShellMaxSeconds*1000),
			}
		}
		out = append(out, def)
	}
	return out
}
