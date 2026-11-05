package netproxy

import (
	"io"
	"log"
	"strings"
	"testing"
)

func TestStartRefusesNonLoopbackListener(t *testing.T) {
	cfg := Config{Listen: "0.0.0.0", Port: 3128, Username: "a", Password: "b", Upstream: Upstream{Endpoints: []Endpoint{{Addr: "x:1", Secret: "0123456789abcdef0123"}}, Insecure: true}}
	if _, err := Start(cfg, log.New(io.Discard, "", 0)); err == nil || !strings.Contains(err.Error(), "回环") {
		t.Fatalf("error=%v", err)
	}
}
