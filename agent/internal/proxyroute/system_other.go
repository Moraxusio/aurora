//go:build !windows

package proxyroute

import (
	"os"
	"strings"
)

func System() map[string]string {
	out := map[string]string{}
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"} {
		v := os.Getenv(k)
		if v == "" {
			v = os.Getenv(strings.ToLower(k))
		}
		if v != "" {
			out[k] = v
		}
	}
	return out
}
