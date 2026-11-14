//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
)

func (s svc) opNetwork(context.Context, json.RawMessage) (any, error) {
	return map[string]any{"proxy_modes": []string{"system", "agent", "direct"}}, nil
}

func (e *Env) proxyFor(p ProviderConfig) func() map[string]string {
	if p.ProxyMode == "agent" && e.AgentProxy != nil {
		return e.AgentProxy
	}
	return e.Proxy
}
