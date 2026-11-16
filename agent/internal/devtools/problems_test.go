package devtools

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTaskProblemsChunkingWindowsPathsAndGoJSON(t *testing.T) {
	re, err := problemMatcher("")
	if err != nil {
		t.Fatal(err)
	}
	var found []map[string]any
	p := taskProblemParser{re: re, emit: func(v map[string]any) error { found = append(found, v); return nil }}
	for _, part := range []string{"C:\\work\\中文.go:12:", "4: warning: bad", "\r\nmain.go:3: error: next"} {
		if err := p.append(part); err != nil {
			t.Fatal(err)
		}
	}
	p.finish()
	if len(found) != 2 || found[0]["file"] != `C:\work\中文.go` || found[0]["column"] != 4 ||
		found[1]["line"] != 3 || found[1]["column"] != 1 {
		t.Fatal(found)
	}
	p.goJSON = true
	data, _ := json.Marshal(map[string]any{"Output": "main.go:42: bad\n"})
	p.append(string(data) + "\n")
	if len(found) != 3 || found[2]["line"] != 42 {
		t.Fatal(found)
	}
}

func TestTaskProblemsCustomRE2AndBudgets(t *testing.T) {
	re, err := problemMatcher(`(?P<file>[a-z.]+)\((?P<line>\d+)\) (?P<message>(a+)+)$`)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	p := taskProblemParser{re: re, emit: func(v map[string]any) error { found++; return nil }}
	p.append("file.go(2) " + strings.Repeat("a", 12000) + "!\n")
	if found != 0 {
		t.Fatal(found)
	}
	p.append(strings.Repeat("x", problemLineMax) + "file.go(2) aaa\n")
	if found != 0 || p.pending != "" || p.oversized {
		t.Fatal("oversized line was parsed")
	}
	p.append(strings.Repeat("file.go(2) aaa\n", 600))
	if found != 500 {
		t.Fatal(found)
	}
	for _, invalid := range []string{"(a)\\1", "abc", strings.Repeat("a", 4097)} {
		if _, err := problemMatcher(invalid); err == nil {
			t.Fatalf("accepted %q", invalid[:min(len(invalid), 20)])
		}
	}
}
