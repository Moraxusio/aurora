package ai

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	MaxOutputLines = 2000
	MaxOutputBytes = 50 * 1024 // 50 KiB (OpenCode Truncate.MAX_BYTES)
)

// TruncateResult holds a tool output after applying OpenCode's 2000-line / 50 KiB cap.
type TruncateResult struct {
	Content   string
	Truncated bool
	SavedPath string
}

// TruncateOutput caps large tool outputs to MaxOutputLines and MaxOutputBytes.
// When spillDir is non-empty and truncation occurs, the full output is saved so
// the agent can inspect specific ranges with `read` or `grep`.
func TruncateOutput(text string, spillDir string, direction string) TruncateResult {
	if len(text) <= MaxOutputBytes && strings.Count(text, "\n") < MaxOutputLines {
		return TruncateResult{Content: text, Truncated: false}
	}

	var savedPath string
	if spillDir != "" {
		if err := os.MkdirAll(spillDir, 0o700); err == nil {
			name := NewID("tool") + ".txt"
			full := filepath.Join(spillDir, name)
			if err := os.WriteFile(full, []byte(text), 0o600); err == nil {
				savedPath = full
			}
		}
	}

	lines := strings.Split(text, "\n")
	var kept []string
	bytesCount := 0
	hitBytes := false

	if direction == "tail" {
		for i := len(lines) - 1; i >= 0 && len(kept) < MaxOutputLines; i-- {
			sz := len(lines[i])
			if len(kept) > 0 {
				sz++
			}
			if bytesCount+sz > MaxOutputBytes {
				hitBytes = true
				break
			}
			kept = append(kept, lines[i])
			bytesCount += sz
		}
		for i, j := 0, len(kept)-1; i < j; i, j = i+1, j-1 {
			kept[i], kept[j] = kept[j], kept[i]
		}
	} else {
		for i := 0; i < len(lines) && len(kept) < MaxOutputLines; i++ {
			line := lines[i]
			if i == 0 && len(line) > MaxOutputBytes {
				kept = append(kept, line[:MaxOutputBytes])
				bytesCount = MaxOutputBytes
				hitBytes = true
				break
			}
			sz := len(line)
			if len(kept) > 0 {
				sz++
			}
			if bytesCount+sz > MaxOutputBytes {
				hitBytes = true
				break
			}
			kept = append(kept, line)
			bytesCount += sz
		}
	}

	preview := strings.Join(kept, "\n")
	var unit string
	var removed int
	if hitBytes {
		removed = len(text) - bytesCount
		unit = "bytes"
	} else {
		removed = len(lines) - len(kept)
		unit = "lines"
	}

	var hint string
	if savedPath != "" {
		hint = fmt.Sprintf("The tool call succeeded but the output was truncated. Full output saved to: %s\nUse grep to search the full content or read with offset/limit to view specific sections.", savedPath)
	} else {
		hint = "Tool output was truncated. Use grep or read with offset/limit to inspect specific sections."
	}

	var out string
	if direction == "tail" {
		out = fmt.Sprintf("...%d %s truncated...\n\n%s\n\n%s", removed, unit, hint, preview)
	} else {
		out = fmt.Sprintf("%s\n\n...%d %s truncated...\n\n%s", preview, removed, unit, hint)
	}
	return TruncateResult{
		Content:   out,
		Truncated: true,
		SavedPath: savedPath,
	}
}
