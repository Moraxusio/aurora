package netproxy

import (
	"io"
	"log"
	"strings"
	"testing"
)

func TestStartRefusesNonLoopbackListener(t *testing.T) {
	cfg := Config{Listen: "0.0.0.0", Port: 3128, Username: "a", Password: "b"}
	if _, err := Start(cfg, log.New(io.Discard, "", 0)); err == nil || !strings.Contains(err.Error(), "回环") {
		t.Fatalf("error=%v", err)
	}
}
