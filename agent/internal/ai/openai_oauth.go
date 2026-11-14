package ai

// Port of OpenCode (MIT), packages/core/src/plugin/provider/openai.ts:
// headless device authorization, code exchange, refresh and ChatGPT routing.
// See THIRD_PARTY_OPENCODE_LICENSE. Auth responses are returned only to the
// requesting client over pinned TLS. Nothing here persists or audits tokens.
import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const OpenAIDeviceClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
const ChatGPTAuthMode = "chatgpt-device"

// Private variables let tests use a stand-in server; clients cannot change
// these addresses or send subscription tokens to a custom gateway.
var openAIIssuer = "https://auth.openai.com"
var codexBaseURL = "https://chatgpt.com/backend-api/codex"

type OAuthCredential struct {
	Access    string `json:"access"`
	Refresh   string `json:"refresh"`
	Expires   int64  `json:"expires"`
	AccountID string `json:"account_id,omitempty"`
}

type deviceCode struct {
	DeviceAuthID string `json:"device_auth_id"`
	UserCode     string `json:"user_code"`
	URL          string `json:"url"`
	IntervalMS   int    `json:"interval_ms"`
	ExpiresAt    int64  `json:"expires_at"`
}

// No redirect may forward an OAuth body or a ChatGPT account header elsewhere.
func subscriptionClient(useProxy bool, proxy func() map[string]string, modes ...string) *http.Client {
	c := newHTTPClient(useProxy, proxy, modes...)
	c.Timeout = 35 * time.Second
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return c
}

func oauthRequest(ctx context.Context, proxy func() map[string]string, useProxy bool, route, contentType string, body []byte, out any, modes ...string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, openAIIssuer+route, bytes.NewReader(body))
	if err != nil {
		return 0, errors.New("无法创建 OpenAI 授权请求")
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("User-Agent", OpenCodeUserAgent)
	c := subscriptionClient(useProxy, proxy, modes...)
	defer c.CloseIdleConnections()
	res, err := c.Do(req)
	if err != nil {
		return 0, errors.New("OpenAI 授权网络请求失败，请检查服务器网络或代理出口")
	}
	defer res.Body.Close()
	// Never return upstream bodies: errors can contain tokens, codes or cookies.
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return res.StatusCode, nil
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(out); err != nil {
		return res.StatusCode, errors.New("OpenAI 授权响应格式不正确")
	}
	return res.StatusCode, nil
}

func oauthStatus(status int) error {
	if status == 403 {
		return errors.New("OpenAI 授权端点拒绝了服务器出口（HTTP 403）；请改用本机授权或更换服务器代理出口。获取设备码阶段尚不能判断订阅资格")
	}
	if status == 401 || status == 400 {
		return errors.New("OpenAI 登录已失效或授权码过期，请重新使用设备码登录")
	}
	return fmt.Errorf("OpenAI 授权失败（HTTP %d），请检查网络、订阅资格及账号的设备码登录设置", status)
}

func beginOpenAIDevice(ctx context.Context, useProxy bool, proxy func() map[string]string, modes ...string) (deviceCode, error) {
	var raw struct {
		DeviceAuthID string          `json:"device_auth_id"`
		UserCode     string          `json:"user_code"`
		Interval     json.RawMessage `json:"interval"`
	}
	body, _ := json.Marshal(map[string]string{"client_id": OpenAIDeviceClientID})
	status, err := oauthRequest(ctx, proxy, useProxy, "/api/accounts/deviceauth/usercode", "application/json", body, &raw, modes...)
	if err != nil {
		return deviceCode{}, err
	}
	if status != 200 {
		return deviceCode{}, oauthStatus(status)
	}
	if raw.DeviceAuthID == "" || raw.UserCode == "" {
		return deviceCode{}, errors.New("OpenAI 未返回设备授权码")
	}
	var interval string
	_ = json.Unmarshal(raw.Interval, &interval)
	if interval == "" {
		interval = string(raw.Interval)
	}
	seconds, _ := strconv.Atoi(interval)
	if seconds <= 0 {
		seconds = 5
	}
	if seconds > 60 {
		seconds = 60
	}
	return deviceCode{raw.DeviceAuthID, raw.UserCode, openAIIssuer + "/codex/device", seconds*1000 + 3000, time.Now().Add(15 * time.Minute).UnixMilli()}, nil
}

type tokenResponse struct {
	IDToken   string `json:"id_token"`
	Access    string `json:"access_token"`
	Refresh   string `json:"refresh_token"`
	ExpiresIn int    `json:"expires_in"`
}

func accountClaim(token string) string {
	parts := bytes.Split([]byte(token), []byte("."))
	if len(parts) < 2 {
		return ""
	}
	b, err := base64.RawURLEncoding.DecodeString(string(parts[1]))
	if err != nil {
		return ""
	}
	var claims struct {
		Account string `json:"chatgpt_account_id"`
		Auth    struct {
			Account string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
		Organizations []struct {
			ID string `json:"id"`
		} `json:"organizations"`
	}
	if json.Unmarshal(b, &claims) != nil {
		return ""
	}
	// Routing metadata only; never use an unverified JWT claim as authentication.
	if claims.Account != "" {
		return claims.Account
	}
	if claims.Auth.Account != "" {
		return claims.Auth.Account
	}
	if len(claims.Organizations) > 0 {
		return claims.Organizations[0].ID
	}
	return ""
}

func credentialFromTokens(t tokenResponse, previous *OAuthCredential) (OAuthCredential, error) {
	if t.Access == "" {
		return OAuthCredential{}, errors.New("OpenAI 未返回访问令牌，请重新登录")
	}
	if t.ExpiresIn <= 0 {
		t.ExpiresIn = 3600
	}
	account := accountClaim(t.IDToken)
	if account == "" {
		account = accountClaim(t.Access)
	}
	refresh := t.Refresh
	if previous != nil {
		if refresh == "" {
			refresh = previous.Refresh
		}
		if account == "" {
			account = previous.AccountID
		}
	}
	if refresh == "" {
		return OAuthCredential{}, errors.New("OpenAI 未返回刷新令牌，请重新登录")
	}
	return OAuthCredential{t.Access, refresh, time.Now().Add(time.Duration(t.ExpiresIn) * time.Second).UnixMilli(), account}, nil
}

func exchangeOpenAIToken(ctx context.Context, useProxy bool, proxy func() map[string]string, form url.Values, previous *OAuthCredential, modes ...string) (OAuthCredential, error) {
	form.Set("client_id", OpenAIDeviceClientID)
	var t tokenResponse
	status, err := oauthRequest(ctx, proxy, useProxy, "/oauth/token", "application/x-www-form-urlencoded", []byte(form.Encode()), &t, modes...)
	if err != nil {
		return OAuthCredential{}, err
	}
	if status != 200 {
		return OAuthCredential{}, oauthStatus(status)
	}
	return credentialFromTokens(t, previous)
}

func pollOpenAIDevice(ctx context.Context, useProxy bool, proxy func() map[string]string, deviceID, userCode string, modes ...string) (*OAuthCredential, error) {
	body, _ := json.Marshal(map[string]string{"device_auth_id": deviceID, "user_code": userCode})
	var auth struct {
		Code     string `json:"authorization_code"`
		Verifier string `json:"code_verifier"`
	}
	status, err := oauthRequest(ctx, proxy, useProxy, "/api/accounts/deviceauth/token", "application/json", body, &auth, modes...)
	if err != nil {
		return nil, err
	}
	if status == 403 || status == 404 {
		return nil, nil
	}
	if status != 200 {
		return nil, oauthStatus(status)
	}
	if auth.Code == "" || auth.Verifier == "" {
		return nil, errors.New("OpenAI 设备授权响应不完整，请重新登录")
	}
	c, err := exchangeOpenAIToken(ctx, useProxy, proxy, url.Values{
		"grant_type": {"authorization_code"}, "code": {auth.Code}, "code_verifier": {auth.Verifier}, "redirect_uri": {openAIIssuer + "/deviceauth/callback"},
	}, nil, modes...)
	return &c, err
}

func prepareSubscription(cfg ProviderConfig) (ProviderConfig, error) {
	if cfg.AuthMode != ChatGPTAuthMode {
		return cfg, nil
	}
	if cfg.APIKey == "" {
		return cfg, errors.New("请先使用 OpenAI 设备码登录 ChatGPT 订阅")
	}
	if cfg.ExpiresAt > 0 && cfg.ExpiresAt <= time.Now().UnixMilli() {
		return cfg, errors.New("ChatGPT 访问令牌已到期，请在客户端重新发送以刷新登录")
	}
	cfg.Protocol = "openai-responses"
	cfg.BaseURL = codexBaseURL
	cfg.Headers = nil // subscription credentials never honor a custom auth/endpoint override
	return cfg, nil
}

func applySubscriptionHeaders(h http.Header, req LLMRequest) {
	h.Set("Authorization", "Bearer "+req.Provider.APIKey)
	h.Del("x-api-key")
	h.Set("originator", "opencode")
	if req.Provider.AccountID != "" {
		h.Set("chatgpt-account-id", req.Provider.AccountID)
	}
	affinity := req.AffinityID
	if affinity == "" {
		affinity = req.SessionID
	}
	if affinity != "" {
		h.Set("session-id", affinity)
	}
}

func subscriptionStatus(status int) error {
	if status == 401 {
		return errors.New("ChatGPT 登录已失效，请重新登录；长任务到期后需在客户端重新发送")
	}
	return &HTTPStatusError{Status: status, Body: fmt.Sprintf("ChatGPT 订阅请求失败（HTTP %d），请检查订阅额度、模型权限或服务器出口", status)}
}

func subscriptionContextError() error {
	return &HTTPStatusError{Status: 400, Body: "context_length_exceeded: ChatGPT 上下文超出限制，请压缩后重试"}
}

// Preserve only an allowlisted error code for automatic compaction, never text
// echoed by an upstream auth service or proxy.
func subscriptionHTTPError(status int, body []byte) error {
	var parsed struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &parsed) == nil && parsed.Error.Code == "context_length_exceeded" {
		return subscriptionContextError()
	}
	return subscriptionStatus(status)
}

// OpenCode uses a catalog, not OpenAI's API-key /v1/models endpoint, for
// subscription sign-ins. These are suggestions, NOT an account entitlement check.
func subscriptionModelSuggestions(cfg ProviderConfig) []ModelInfo {
	ids := []string{"gpt-6.1-sol", "gpt-5.2-codex", "gpt-5.1-codex", "gpt-5-codex"}
	if cfg.Model != "" {
		ids = append([]string{cfg.Model}, ids...)
	}
	seen := map[string]bool{}
	var models []ModelInfo
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		models = append(models, ModelInfo{ID: id, ContextWindow: subscriptionContextCap(id)})
	}
	return models
}

// OpenCode openai-context-caps.ts: default subscription INPUT budgets.
func subscriptionContextCap(model string) int {
	if !strings.HasPrefix(model, "gpt-") {
		return 500_000
	}
	var major, minor int
	_, _ = fmt.Sscanf(strings.TrimPrefix(model, "gpt-"), "%d.%d", &major, &minor)
	if major > 6 || major == 6 && minor >= 1 {
		return 500_000
	}
	return 272_000
}
