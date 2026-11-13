package ai

import "encoding/json"

func runtimeInfo(cfg ProviderConfig) *RuntimeInfo {
	return &RuntimeInfo{ProviderID: cfg.ID, ProviderName: cfg.Name, Model: cfg.Model, Protocol: cfg.Protocol, AuthMode: cfg.AuthMode}
}

func contextLimit(cfg ProviderConfig) (int, string) {
	if cfg.ContextWindow > 0 {
		return cfg.ContextWindow, "configured"
	}
	if cfg.AuthMode == ChatGPTAuthMode {
		return subscriptionContextCap(cfg.Model), "default"
	}
	return defaultContextWindow(cfg.Model), "default"
}

func contextOverhead(system []string, tools []ToolDef) int {
	n := 0
	for _, s := range system {
		n += EstimateTokens(s)
	}
	b, _ := json.Marshal(tools)
	return n + EstimateTokens(string(b))
}

func activeContext(s *Session, cfg ProviderConfig, overhead int) *ContextInfo {
	limit, source := contextLimit(cfg)
	lastInput := 0
	if s.Context != nil {
		lastInput = s.Context.LastInput
	}
	return &ContextInfo{Tokens: EstimateMessagesTokens(BuildActiveHistory(s.Messages)) + overhead, Limit: limit, LimitSource: source, LastInput: lastInput, Estimated: true, Overhead: overhead}
}
