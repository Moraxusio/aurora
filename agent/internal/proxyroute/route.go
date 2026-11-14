// Package proxyroute selects an explicit execution-side network route without
// changing the host environment or exporting listener credentials to clients.
package proxyroute

import (
	"errors"
	"net/http"
	"net/url"
	"strings"

	"golang.org/x/net/http/httpproxy"
)

func Valid(mode string) bool {
	return mode == "" || mode == "system" || mode == "agent" || mode == "direct"
}

func Values(mode string, agent func() map[string]string) (map[string]string, error) {
	switch mode {
	case "system":
		return System(), nil
	case "direct":
		return map[string]string{}, nil
	case "agent":
		if agent != nil {
			v := agent()
			if HasProxy(v) {
				return v, nil
			}
		}
		return nil, errors.New("Aurora agent 代理不可用，请打开代理服务并选择节点")
	default:
		return nil, errors.New("未知的代理出口")
	}
}

func value(env map[string]string, name string) string {
	if v := env[name]; v != "" {
		return v
	}
	return env[strings.ToLower(name)]
}
func HasProxy(env map[string]string) bool {
	return value(env, "HTTP_PROXY") != "" || value(env, "HTTPS_PROXY") != "" || value(env, "ALL_PROXY") != ""
}

func HTTP(mode string, agent func() map[string]string) func(*http.Request) (*url.URL, error) {
	env, err := Values(mode, agent)
	if err != nil {
		return func(*http.Request) (*url.URL, error) { return nil, err }
	}
	httpURL, httpsURL, all := value(env, "HTTP_PROXY"), value(env, "HTTPS_PROXY"), value(env, "ALL_PROXY")
	if httpURL == "" {
		httpURL = all
	}
	if httpsURL == "" {
		httpsURL = all
	}
	// Config respects NO_PROXY and local addresses, and does not cache the first
	// process environment forever as http.ProxyFromEnvironment does.
	resolve := (&httpproxy.Config{HTTPProxy: httpURL, HTTPSProxy: httpsURL, NoProxy: value(env, "NO_PROXY")}).ProxyFunc()
	return func(r *http.Request) (*url.URL, error) { return resolve(r.URL) }
}

// Replace removes both spellings of inherited proxy variables before setting
// the selected route. A direct child cannot accidentally keep ALL_PROXY.
func Replace(base []string, env map[string]string) []string {
	out := make([]string, 0, len(base)+8)
	for _, entry := range base {
		k, _, _ := strings.Cut(entry, "=")
		switch strings.ToUpper(k) {
		case "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY":
			continue
		}
		out = append(out, entry)
	}
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"} {
		if v := value(env, k); v != "" {
			out = append(out, k+"="+v, strings.ToLower(k)+"="+v)
		}
	}
	return out
}
