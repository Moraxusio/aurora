package ai

import (
	"fmt"
	"strings"
	"unicode"
)

var capabilityNames = []string{
	"tool_calling", "image_input", "pdf_input", "read", "glob", "grep",
	"write", "edit", "apply_patch", "shell", "webfetch", "websearch",
	"todowrite", "subagent", "question",
}

func (p ProviderConfig) allows(name string) bool {
	enabled, set := p.Capabilities[name]
	return !set || enabled
}

func resolvedCapabilities(p ProviderConfig) map[string]bool {
	out := make(map[string]bool, len(capabilityNames))
	for _, name := range capabilityNames {
		out[name] = p.allows(name)
	}
	return out
}

func prepareModelOptions(p ProviderConfig) (ProviderConfig, error) {
	caps := make(map[string]bool, len(p.Capabilities))
	for name, enabled := range p.Capabilities {
		known := false
		for _, key := range capabilityNames {
			known = known || key == name
		}
		if !known {
			return p, fmt.Errorf("unknown model capability %q; update the agent to use this setting", name)
		}
		caps[name] = enabled
	}
	p.Capabilities = caps // admission owns an immutable snapshot, including queued inputs
	p.ReasoningEffort = strings.TrimSpace(p.ReasoningEffort)
	if len(p.ReasoningEffort) > 64 || strings.IndexFunc(p.ReasoningEffort, unicode.IsControl) >= 0 {
		return p, fmt.Errorf("reasoning effort must be at most 64 characters without control characters")
	}
	switch p.ReasoningMode {
	case "", "protocol":
	case "disabled":
		p.ReasoningEffort = ""
	case "anthropic-adaptive", "anthropic-budget":
		if p.Protocol != "anthropic-messages" && p.Protocol != "anthropic" {
			return p, fmt.Errorf("Anthropic thinking mode requires the Anthropic Messages protocol")
		}
	default:
		return p, fmt.Errorf("unknown reasoning mode %q", p.ReasoningMode)
	}
	if p.ReasoningMode == "anthropic-budget" && (p.ThinkingBudget < 1024 || p.ThinkingBudget > 1_000_000) {
		return p, fmt.Errorf("thinking budget must be between 1024 and 1000000 tokens")
	}
	return p, nil
}
