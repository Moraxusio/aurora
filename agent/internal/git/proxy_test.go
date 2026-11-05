//go:build linux

package git

import (
	"strings"
	"testing"
)

func hasEnv(env []string, key string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			return true
		}
	}
	return false
}

// With the proxy service on, git's environment carries the proxy variables
// (D-69). The proxy switch is the only thing that decides this for git.
func TestGitGetsProxyWhenServiceOn(t *testing.T) {
	on := func() map[string]string {
		return map[string]string{"HTTPS_PROXY": "http://127.0.0.1:7890", "ALL_PROXY": "socks5h://127.0.0.1:7890"}
	}
	g, err := gitFor(t.TempDir(), on)
	if err != nil {
		t.Fatal(err)
	}
	if !hasEnv(g.env, "HTTPS_PROXY") || !hasEnv(g.env, "ALL_PROXY") {
		t.Fatalf("proxy on: git env lacks proxy variables: %v", g.env)
	}
}

// With the proxy service off (hook returns nil), git runs without proxy
// variables.
func TestGitNoProxyWhenServiceOff(t *testing.T) {
	off := func() map[string]string { return nil }
	g, err := gitFor(t.TempDir(), off)
	if err != nil {
		t.Fatal(err)
	}
	if hasEnv(g.env, "HTTPS_PROXY") || hasEnv(g.env, "ALL_PROXY") {
		t.Fatalf("proxy off: git env still carries proxy variables: %v", g.env)
	}
}

// A nil hook (no proxy wiring at all) also gives git no proxy variables.
func TestGitNoProxyWithoutHook(t *testing.T) {
	g, err := gitFor(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if hasEnv(g.env, "HTTPS_PROXY") {
		t.Fatalf("nil hook: git env carries proxy variables: %v", g.env)
	}
}

// The switch takes effect on the next call, not only at start (D-54): the same
// hook read at two times gives two environments.
func TestProxySwitchAppliesToNextCall(t *testing.T) {
	on := true
	hook := func() map[string]string {
		if on {
			return map[string]string{"HTTPS_PROXY": "http://127.0.0.1:7890"}
		}
		return nil
	}
	first, _ := gitFor(t.TempDir(), hook)
	on = false
	second, _ := gitFor(t.TempDir(), hook)
	if !hasEnv(first.env, "HTTPS_PROXY") || hasEnv(second.env, "HTTPS_PROXY") {
		t.Fatalf("switch not applied: first=%v second=%v", hasEnv(first.env, "HTTPS_PROXY"), hasEnv(second.env, "HTTPS_PROXY"))
	}
}
