package proxyroute

import (
	"net/http"
	"strings"
	"testing"
)

func TestRoutesRespectSchemeBypassAndRefuseMissingAgent(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:18101")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:18102")
	t.Setenv("ALL_PROXY", "socks5://127.0.0.1:18103")
	t.Setenv("NO_PROXY", "bypass.fixture")
	for _, tc := range []struct{ mode, target, want string }{
		{"system", "http://api.fixture", "127.0.0.1:18101"},
		{"system", "https://api.fixture", "127.0.0.1:18102"},
		{"system", "https://bypass.fixture", ""},
		{"direct", "https://api.fixture", ""},
		{"agent", "https://api.fixture", "127.0.0.1:18104"},
	} {
		r, _ := http.NewRequest("GET", tc.target, nil)
		p, err := HTTP(tc.mode, func() map[string]string { return map[string]string{"https_proxy": "http://127.0.0.1:18104"} })(r)
		if err != nil {
			t.Fatal(err)
		}
		got := ""
		if p != nil {
			got = p.Host
		}
		if got != tc.want {
			t.Fatalf("%s %s route %q, want %q", tc.mode, tc.target, got, tc.want)
		}
	}
	r, _ := http.NewRequest("GET", "https://api.fixture", nil)
	if _, err := HTTP("agent", nil)(r); err == nil {
		t.Fatal("agent selection silently fell back")
	}
	if _, err := Values("invalid", nil); err == nil {
		t.Fatal("invalid mode accepted")
	}
}

func TestChildEnvironmentHasOnlyTheSelectedProxy(t *testing.T) {
	base := []string{"KEEP=yes", "HTTP_PROXY=http://old", "https_proxy=http://old2", "All_Proxy=socks5://old", "NO_PROXY=old"}
	direct := Replace(base, nil)
	if strings.Join(direct, ",") != "KEEP=yes" {
		t.Fatalf("direct inherited a proxy: %v", direct)
	}
	out := Replace(base, map[string]string{"HTTP_PROXY": "http://fixture", "NO_PROXY": "localhost"})
	joined := strings.Join(out, ",")
	if strings.Contains(joined, "old") || !strings.Contains(joined, "http_proxy=http://fixture") || !strings.Contains(joined, "HTTP_PROXY=http://fixture") {
		t.Fatalf("mixed routes: %v", out)
	}
}
