package winlocal

import (
	"golang.org/x/sys/windows/registry"
	"strings"
)

func systemProxy(out map[string]string) map[string]string {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.QUERY_VALUE)
	if err != nil {
		return out
	}
	defer k.Close()
	enabled, _, _ := k.GetIntegerValue("ProxyEnable")
	if enabled != 1 {
		return out
	}
	server, _, _ := k.GetStringValue("ProxyServer")
	set := func(key, value string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		if !strings.Contains(value, "://") {
			value = "http://" + value
		}
		out[key] = value
	}
	if !strings.Contains(server, "=") {
		set("HTTP_PROXY", server)
		set("HTTPS_PROXY", server)
	} else {
		for _, part := range strings.Split(server, ";") {
			scheme, value, ok := strings.Cut(part, "=")
			if ok {
				switch strings.ToLower(strings.TrimSpace(scheme)) {
				case "http":
					set("HTTP_PROXY", value)
				case "https":
					set("HTTPS_PROXY", value)
				}
			}
		}
	}
	if out["NO_PROXY"] == "" {
		out["NO_PROXY"] = "localhost,127.0.0.1,::1"
	}
	return out
}
