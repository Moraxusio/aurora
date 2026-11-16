//go:build linux || windows

package files

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCancelledFileListDoesNotPoisonCache(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "found.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	e := &Env{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	e.cachedFiles(ctx, dir, time.Minute)
	if got := e.cachedFiles(context.Background(), dir, time.Minute); len(got) != 1 || got[0] != "found.txt" {
		t.Fatalf("cancelled file list cached: %v", got)
	}
}

func TestSearchWorkersRespectSharedBudget(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 32; i++ {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%d.txt", i)), []byte(strings.Repeat("needle\n", 600)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	e := &Env{Roots: []Root{{ID: "work", Path: dir}}}
	for _, limit := range []int{1, 7, 501} {
		raw, _ := json.Marshal(map[string]any{"root": "work", "path": "/", "query": "needle", "max": limit})
		res, err := e.fsSearch(context.Background(), raw)
		if err != nil {
			t.Fatal(err)
		}
		m := res.(map[string]any)
		count := 0
		for _, f := range m["files"].([]fileMatches) {
			count += len(f.Matches)
		}
		if count != limit || m["total"].(int64) != int64(limit) {
			t.Fatalf("limit=%d returned=%d total=%v", limit, count, m["total"])
		}
	}
}
