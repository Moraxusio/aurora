//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"net/url"

	"aurora3/internal/wire"
)

// Credentials only travel on the requesting RPC, never via ai.stream or audit.
func (s svc) opAuthBegin(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		UseProxy  bool   `json:"use_proxy"`
		ProxyMode string `json:"proxy_mode"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	d, err := beginOpenAIDevice(ctx, in.UseProxy, s.proxyFor(ProviderConfig{ProxyMode: in.ProxyMode}), in.ProxyMode)
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	return d, nil
}

func (s svc) opAuthPoll(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		DeviceID  string `json:"device_auth_id"`
		UserCode  string `json:"user_code"`
		UseProxy  bool   `json:"use_proxy"`
		ProxyMode string `json:"proxy_mode"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if in.DeviceID == "" || in.UserCode == "" || len(in.DeviceID) > 4096 || len(in.UserCode) > 128 {
		return nil, wire.Errf(wire.CodeBadRequest, "设备授权参数无效")
	}
	c, err := pollOpenAIDevice(ctx, in.UseProxy, s.proxyFor(ProviderConfig{ProxyMode: in.ProxyMode}), in.DeviceID, in.UserCode, in.ProxyMode)
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	if c == nil {
		return map[string]any{"status": "pending"}, nil
	}
	return map[string]any{"status": "authorized", "credential": c}, nil
}

func (s svc) opAuthRefresh(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		Refresh   string `json:"refresh"`
		AccountID string `json:"account_id"`
		UseProxy  bool   `json:"use_proxy"`
		ProxyMode string `json:"proxy_mode"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if in.Refresh == "" || len(in.Refresh) > 65536 {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少刷新令牌，请重新登录")
	}
	c, err := exchangeOpenAIToken(ctx, in.UseProxy, s.proxyFor(ProviderConfig{ProxyMode: in.ProxyMode}), url.Values{"grant_type": {"refresh_token"}, "refresh_token": {in.Refresh}}, &OAuthCredential{Refresh: in.Refresh, AccountID: in.AccountID}, in.ProxyMode)
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	return map[string]any{"credential": c}, nil
}
