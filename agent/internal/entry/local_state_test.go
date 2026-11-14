package entry

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLocalServiceStateExcludesBootstrapIdentity(t *testing.T) {
	c := Config{Kind: "local", Token: "synthetic-ephemeral-token", Listen: "127.0.0.1:12345", Services: map[string]bool{"proxy": false}, Proxy: json.RawMessage(`{"port":23456}`)}
	path := filepath.Join(t.TempDir(), "local-agent.json")
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	if len(saved) != 2 || saved["token"] != nil || saved["listen"] != nil || saved["roots"] != nil {
		t.Fatal("local state persisted bootstrap identity")
	}
	if saved["services"].(map[string]any)["proxy"] != false || saved["proxy"].(map[string]any)["port"] != float64(23456) {
		t.Fatal("service choices were lost")
	}
}
