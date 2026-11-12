//go:build linux

package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"aurora3/internal/paths"
)

// Root mirrors files.Root so ai never imports another service (D-40).
type Root struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
}

// Auditor records mutating operations (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// ToolExecResult is the structured output of one tool invocation.
type ToolExecResult struct {
	Output   string
	IsError  bool
	Metadata map[string]any
}

type toolContext struct {
	env        *Env
	session    *Session
	provider   ProviderConfig
	rootPath   string
	absWorkdir string
	messageID  string
	callID     string
	depth      int
}

// ToolDefinitions returns OpenCode's exact tool names, descriptions, and JSON schemas
// filtered by the active agent mode ("build", "plan", "explore", "general").
func ToolDefinitions(agentMode string, depth int) []ToolDef {
	readTool := ToolDef{
		Name:        "read",
		Description: "Read a file or directory from the local filesystem. Lines are numbered starting at 1 (`1: content`). By default reads up to 2000 lines from the start of the file. Use offset and limit to inspect specific sections of large files.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{
					"type":        "string",
					"description": "File or directory to read (relative to working directory or absolute within root)",
				},
				"offset": map[string]any{
					"type":        "integer",
					"description": "The 1-indexed line or directory entry to start reading from",
				},
				"limit": map[string]any{
					"type":        "integer",
					"description": "Maximum number of lines or directory entries to read (defaults to 2000)",
				},
			},
			"required": []string{"path"},
		},
	}

	writeTool := ToolDef{
		Name:        "write",
		Description: "Write a file to the local filesystem, creating parent directories if needed and overwriting existing content. Prefer edit for targeted modifications to existing files.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{
					"type":        "string",
					"description": "Path to the file to write to",
				},
				"content": map[string]any{
					"type":        "string",
					"description": "Content to write to the file",
				},
			},
			"required": []string{"path", "content"},
		},
	}

	editTool := ToolDef{
		Name:        "edit",
		Description: "Edit the contents of a file by finding and replacing exact text. When editing text from Read output, preserve the exact indentation (tabs or spaces) and omit the line-number prefix, such as `1: `. Never include the prefix in oldString or newString. Write line breaks as \\n; the file's existing CRLF or LF line endings are matched and preserved. If there is no exact match, the edit retries while ignoring typographic quote, dash, and space variants, then trailing whitespace on each line. By default, oldString must identify a UNIQUE location. Multiple matches FAIL unless replaceAll is true.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{
					"type":        "string",
					"description": "File to edit",
				},
				"oldString": map[string]any{
					"type":        "string",
					"description": "Exact text to find and replace",
				},
				"newString": map[string]any{
					"type":        "string",
					"description": "Text to replace oldString with (must differ from oldString)",
				},
				"replaceAll": map[string]any{
					"type":        "boolean",
					"description": "Whether to replace every occurrence of oldString. Defaults to false.",
				},
			},
			"required": []string{"path", "oldString", "newString"},
		},
	}

	globTool := ToolDef{
		Name:        "glob",
		Description: "Fast file pattern matching tool that works with any codebase size. Supports patterns like `**/*.go` or `src/**/*.ts`. Returns matching file paths sorted by modification time.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern": map[string]any{
					"type":        "string",
					"description": "Glob pattern to match files against",
				},
				"path": map[string]any{
					"type":        "string",
					"description": "Directory to search. Defaults to the current working directory.",
				},
				"hidden": map[string]any{
					"type":        "boolean",
					"description": "Include hidden files and directories (starting with `.`). Defaults to false.",
				},
			},
			"required": []string{"pattern"},
		},
	}

	grepTool := ToolDef{
		Name:        "grep",
		Description: "Fast content search tool that searches file contents using regular expressions. Supports full regex syntax and file glob filtering.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern": map[string]any{
					"type":        "string",
					"description": "Regular expression or literal text to match in file contents.",
				},
				"path": map[string]any{
					"type":        "string",
					"description": "File or directory to search. Defaults to the current working directory.",
				},
				"include": map[string]any{
					"type":        "string",
					"description": "File glob filter (e.g. `*.go`, `*.{ts,tsx}`).",
				},
			},
			"required": []string{"pattern"},
		},
	}

	shellTool := ToolDef{
		Name:        "shell",
		Description: "Execute a shell command on Linux using bash and return its output. Quote file paths containing spaces or special characters. Prefer dedicated tools over shell commands when possible. When output is large, the full result is saved to a file and a truncated preview is returned.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"command": map[string]any{
					"type":        "string",
					"description": "Shell command string to execute",
				},
				"workdir": map[string]any{
					"type":        "string",
					"description": "Working directory to execute the command in. Defaults to the current working directory.",
				},
				"timeout": map[string]any{
					"type":        "integer",
					"description": "Timeout in milliseconds. Defaults to 120000 (2 minutes).",
				},
			},
			"required": []string{"command"},
		},
	}

	todoTool := ToolDef{
		Name: "todowrite",
		Description: `Create and update a todo list for the current session. The user sees it as your working plan.
Use it proactively when a task has 3 or more distinct steps, or when the user gives several tasks or asks for a todo list. Skip it for a single simple task or a purely conversational request.
- Send the full list on every call; it replaces the previous one.
- Mark items in_progress when you start them and completed as soon as they're actually done.`,
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"todos": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"id":       map[string]any{"type": "string", "description": "Unique identifier for the todo item"},
							"content":  map[string]any{"type": "string", "description": "Brief description of the task"},
							"status":   map[string]any{"type": "string", "enum": []string{"pending", "in_progress", "completed", "cancelled"}},
							"priority": map[string]any{"type": "string", "enum": []string{"high", "medium", "low"}},
						},
						"required": []string{"id", "content", "status"},
					},
				},
			},
			"required": []string{"todos"},
		},
	}

	subagentTool := ToolDef{
		Name: "subagent",
		Description: `Spawn a specialized child agent in an isolated context window to research or execute a focused sub-task, returning its final report.
Available subagents:
- explore: Fast read-only codebase exploration & search specialist (specify thoroughness: quick, medium, very thorough).
- general: General-purpose multi-step research and execution subagent.`,
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"agent": map[string]any{
					"type":        "string",
					"description": "Subagent type: `explore` or `general`",
				},
				"description": map[string]any{
					"type":        "string",
					"description": "Short 3-5 word label for the task, displayed to the user",
				},
				"prompt": map[string]any{
					"type":        "string",
					"description": "Detailed task instructions for the subagent",
				},
			},
			"required": []string{"agent", "description", "prompt"},
		},
	}

	// OpenCode's webfetch + websearch (web.go) are offered in every mode.
	web := []ToolDef{webFetchToolDef, webSearchToolDef}
	switch agentMode {
	case "explore":
		return append([]ToolDef{readTool, globTool, grepTool, shellTool}, web...)
	case "plan":
		out := append([]ToolDef{readTool, globTool, grepTool, shellTool}, web...)
		out = append(out, todoTool)
		if depth == 0 {
			out = append(out, subagentTool)
		}
		return out
	case "general":
		out := append([]ToolDef{readTool, writeTool, editTool, globTool, grepTool, shellTool}, web...)
		return append(out, todoTool)
	default: // "build"
		out := append([]ToolDef{readTool, writeTool, editTool, globTool, grepTool, shellTool}, web...)
		out = append(out, todoTool)
		if depth == 0 {
			out = append(out, subagentTool)
		}
		return out
	}
}

func resolveToolPath(tc toolContext, rawPath string, allowSpill bool) (absPath string, relDisplay string, err error) {
	p := strings.TrimSpace(rawPath)
	if p == "" {
		p = tc.absWorkdir
	} else if !filepath.IsAbs(p) {
		p = filepath.Join(tc.absWorkdir, p)
	}
	p = filepath.Clean(p)

	// Allow reading tool spillover files created by TruncateOutput under StateDir/ai/tool-output
	if allowSpill && tc.env.StateDir != "" {
		spill := filepath.Clean(filepath.Join(tc.env.StateDir, "ai", "tool-output"))
		if paths.Within(spill, p) {
			return p, p, nil
		}
	}

	// Ensure target stays within the configured root (resolving existing symlinks safely)
	checkDir := p
	for {
		if _, statErr := os.Lstat(checkDir); statErr == nil {
			break
		}
		parent := filepath.Dir(checkDir)
		if parent == checkDir {
			break
		}
		checkDir = parent
	}
	realBase, evalErr := filepath.EvalSymlinks(checkDir)
	if evalErr == nil {
		suffix, _ := filepath.Rel(checkDir, p)
		resolved := filepath.Clean(filepath.Join(realBase, suffix))
		realRoot := tc.rootPath
		if r, e := filepath.EvalSymlinks(tc.rootPath); e == nil {
			realRoot = r
		}
		if !paths.Within(realRoot, resolved) {
			return "", "", fmt.Errorf("path escapes configured root (%s): %s", tc.session.Root, rawPath)
		}
		p = resolved
	} else if !paths.Within(tc.rootPath, p) {
		return "", "", fmt.Errorf("path escapes configured root (%s): %s", tc.session.Root, rawPath)
	}

	rel, relErr := filepath.Rel(tc.absWorkdir, p)
	if relErr != nil || strings.HasPrefix(rel, "..") {
		rel = p
	} else {
		rel = filepath.ToSlash(rel)
	}
	return p, rel, nil
}

func executeTool(ctx context.Context, tc toolContext, name string, rawInput json.RawMessage) ToolExecResult {
	spillDir := ""
	if tc.env.StateDir != "" {
		spillDir = filepath.Join(tc.env.StateDir, "ai", "tool-output")
	}

	checkPerm := func(action, resource string, meta map[string]any) error {
		eff, reason := tc.env.perms.Evaluate(tc.session.ID, tc.session.Agent, tc.session.PermissionMode, action, resource)
		if eff == "deny" {
			return errors.New(reason)
		}
		if eff == "ask" {
			q := PermissionQuestion{
				ID:        NewID("perm"),
				SessionID: tc.session.ID,
				MessageID: tc.messageID,
				CallID:    tc.callID,
				Tool:      name,
				Action:    action,
				Resource:  resource,
				Reason:    reason,
				Metadata:  meta,
			}
			return tc.env.perms.Ask(ctx, q, func(pq PermissionQuestion) {
				tc.env.broadcast(StreamEvent{
					Type:       "permission.ask",
					SessionID:  tc.session.ID,
					MessageID:  tc.messageID,
					ToolCallID: tc.callID,
					Permission: &pq,
				})
			})
		}
		return nil
	}

	var res ToolExecResult
	switch name {
	case "read":
		res = execReadTool(ctx, tc, rawInput, checkPerm)
	case "write":
		res = execWriteTool(ctx, tc, rawInput, checkPerm)
	case "edit":
		res = execEditTool(ctx, tc, rawInput, checkPerm)
	case "glob":
		res = execGlobTool(ctx, tc, rawInput)
	case "grep":
		res = execGrepTool(ctx, tc, rawInput)
	case "shell":
		res = execShellTool(ctx, tc, rawInput, checkPerm)
	case "webfetch":
		res = execWebFetch(ctx, tc, rawInput, checkPerm)
	case "websearch":
		res = execWebSearch(ctx, tc, rawInput, checkPerm)
	case "todowrite":
		res = execTodoWriteTool(tc, rawInput)
	case "subagent":
		res = execSubagentTool(ctx, tc, rawInput, checkPerm)
	default:
		return ToolExecResult{
			Output:  fmt.Sprintf("Unknown tool %q. Use one of the declared tools.", name),
			IsError: true,
		}
	}

	if !res.IsError {
		dir := "head"
		if name == "shell" {
			dir = "tail"
		}
		tr := TruncateOutput(res.Output, spillDir, dir)
		res.Output = tr.Content
		if tr.Truncated {
			if res.Metadata == nil {
				res.Metadata = map[string]any{}
			}
			res.Metadata["truncated"] = true
			if tr.SavedPath != "" {
				res.Metadata["saved_path"] = tr.SavedPath
			}
		}
	}
	return res
}

func execReadTool(_ context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		Path   string `json:"path"`
		File   string `json:"filePath"` // alias tolerance
		Offset int    `json:"offset"`
		Limit  int    `json:"limit"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid read arguments: " + err.Error(), IsError: true}
	}
	targetRaw := in.Path
	if targetRaw == "" {
		targetRaw = in.File
	}
	abs, disp, err := resolveToolPath(tc, targetRaw, true)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	if err := checkPerm("read", disp, nil); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	st, err := os.Stat(abs)
	if err != nil {
		return ToolExecResult{Output: fmt.Sprintf("File not found: %s", targetRaw), IsError: true}
	}

	offset := in.Offset
	if offset < 1 {
		offset = 1
	}
	limit := in.Limit
	if limit <= 0 {
		limit = 2000
	}

	if st.IsDir() {
		entries, err := os.ReadDir(abs)
		if err != nil {
			return ToolExecResult{Output: err.Error(), IsError: true}
		}
		var names []string
		for _, e := range entries {
			nm := e.Name()
			if e.IsDir() {
				nm += "/"
			}
			names = append(names, nm)
		}
		sort.Strings(names)
		start := offset - 1
		if start > len(names) {
			start = len(names)
		}
		end := start + limit
		if end > len(names) {
			end = len(names)
		}
		var out strings.Builder
		fmt.Fprintf(&out, "Directory %s (%d entries):\n", abs, len(names))
		for i := start; i < end; i++ {
			fmt.Fprintf(&out, "%d: %s\n", i+1, names[i])
		}
		if end < len(names) {
			fmt.Fprintf(&out, "\n(Showing entries %d-%d of %d. Use offset=%d to read more.)", start+1, end, len(names), end+1)
		}
		return ToolExecResult{Output: out.String(), Metadata: map[string]any{"path": disp}}
	}

	if st.Size() > 8*1024*1024 {
		return ToolExecResult{
			Output:  fmt.Sprintf("File %s is %d bytes (> 8 MiB). Use grep or shell head/tail to inspect specific parts.", disp, st.Size()),
			IsError: true,
		}
	}

	data, err := os.ReadFile(abs)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	// Detect binary file (null bytes or invalid UTF-8)
	sample := data
	if len(sample) > 8192 {
		sample = sample[:8192]
	}
	if len(data) > 0 && (bytes.IndexByte(sample, 0) >= 0 || !utf8.Valid(sample)) {
		return ToolExecResult{
			Output:  fmt.Sprintf("Cannot read binary file %s (%d bytes).", disp, len(data)),
			IsError: true,
		}
	}

	text := strings.ReplaceAll(strings.TrimPrefix(string(data), utf8BOM), "\r\n", "\n")
	if text == "" {
		return ToolExecResult{Output: "(File is empty)", Metadata: map[string]any{"path": disp}}
	}
	lines := strings.Split(text, "\n")
	// Drop synthetic trailing empty string if file ends with \n
	if len(lines) > 1 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	start := offset - 1
	if start >= len(lines) {
		return ToolExecResult{
			Output:  fmt.Sprintf("Offset %d exceeds file length (%d lines).", offset, len(lines)),
			IsError: true,
		}
	}
	end := start + limit
	if end > len(lines) {
		end = len(lines)
	}

	var b strings.Builder
	bytesUsed := 0
	actualEnd := start
	for i := start; i < end; i++ {
		ln := lines[i]
		if len(ln) > 2000 {
			ln = ln[:2000] + "... [line truncated]"
		}
		formatted := fmt.Sprintf("%d: %s\n", i+1, ln)
		if bytesUsed+len(formatted) > MaxOutputBytes && i > start {
			break
		}
		b.WriteString(formatted)
		bytesUsed += len(formatted)
		actualEnd = i + 1
	}
	if actualEnd < len(lines) {
		fmt.Fprintf(&b, "\n(Showing lines %d-%d of %d. Use offset=%d to continue reading.)", start+1, actualEnd, len(lines), actualEnd+1)
	}
	return ToolExecResult{
		Output:   strings.TrimRight(b.String(), "\n"),
		Metadata: map[string]any{"path": disp, "lines": actualEnd - start, "total_lines": len(lines)},
	}
}

func execWriteTool(_ context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		Path    string `json:"path"`
		File    string `json:"filePath"`
		Content string `json:"content"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid write arguments: " + err.Error(), IsError: true}
	}
	targetRaw := in.Path
	if targetRaw == "" {
		targetRaw = in.File
	}
	abs, disp, err := resolveToolPath(tc, targetRaw, false)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	var before string
	var permMode os.FileMode = 0o644
	if st, statErr := os.Stat(abs); statErr == nil {
		if st.IsDir() {
			return ToolExecResult{Output: fmt.Sprintf("Path is a directory, not a file: %s", targetRaw), IsError: true}
		}
		permMode = st.Mode().Perm()
		if oldBytes, rErr := os.ReadFile(abs); rErr == nil && len(oldBytes) <= 2*1024*1024 {
			before = string(oldBytes)
		}
	}

	diff := ComputeFileDiff(disp, before, in.Content)
	if err := checkPerm("write", disp, map[string]any{"diff": diff}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	if err := atomicWriteFile(abs, []byte(in.Content), permMode); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.write", map[string]any{"session": tc.session.ID, "path": abs, "bytes": len(in.Content)})
	}
	verb := "Updated"
	if diff.Status == "added" {
		verb = "Created"
	}
	return ToolExecResult{
		Output:   fmt.Sprintf("%s %s (+%d -%d)", verb, disp, diff.Additions, diff.Deletions),
		Metadata: map[string]any{"files": []FileDiff{diff}},
	}
}

func execEditTool(_ context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		Path       string `json:"path"`
		File       string `json:"filePath"`
		OldString  string `json:"oldString"`
		NewString  string `json:"newString"`
		ReplaceAll bool   `json:"replaceAll"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid edit arguments: " + err.Error(), IsError: true}
	}
	targetRaw := in.Path
	if targetRaw == "" {
		targetRaw = in.File
	}
	abs, disp, err := resolveToolPath(tc, targetRaw, false)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	st, err := os.Stat(abs)
	if err != nil {
		return ToolExecResult{Output: fmt.Sprintf("File not found: %s", targetRaw), IsError: true}
	}
	if st.IsDir() {
		return ToolExecResult{Output: fmt.Sprintf("Path is a directory, not a file: %s", targetRaw), IsError: true}
	}
	origBytes, err := os.ReadFile(abs)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	editRes, err := ApplyEdit(disp, string(origBytes), in.OldString, in.NewString, in.ReplaceAll)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	if err := checkPerm("edit", disp, map[string]any{"diff": editRes.Diff}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	if err := atomicWriteFile(abs, []byte(editRes.Content), st.Mode().Perm()); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.edit", map[string]any{"session": tc.session.ID, "path": abs, "replacements": editRes.Replacements})
	}
	plural := "s"
	if editRes.Replacements == 1 {
		plural = ""
	}
	return ToolExecResult{
		Output:   fmt.Sprintf("Edited %s (%d replacement%s, +%d -%d)", disp, editRes.Replacements, plural, editRes.Diff.Additions, editRes.Diff.Deletions),
		Metadata: map[string]any{"files": []FileDiff{editRes.Diff}, "replacements": editRes.Replacements},
	}
}

func atomicWriteFile(absPath string, content []byte, mode os.FileMode) error {
	dir := filepath.Dir(absPath)
	tmp, err := os.CreateTemp(dir, ".aurora-ai-*")
	if err != nil {
		return os.WriteFile(absPath, content, mode)
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, absPath); err != nil {
		_ = os.Remove(tmpName)
		return os.WriteFile(absPath, content, mode)
	}
	return nil
}

func execGlobTool(ctx context.Context, tc toolContext, rawInput json.RawMessage) ToolExecResult {
	var in struct {
		Pattern string `json:"pattern"`
		Path    string `json:"path"`
		Hidden  bool   `json:"hidden"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid glob arguments: " + err.Error(), IsError: true}
	}
	if strings.TrimSpace(in.Pattern) == "" {
		return ToolExecResult{Output: "pattern must not be empty", IsError: true}
	}
	searchDir, _, err := resolveToolPath(tc, in.Path, false)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	re, err := globToRegex(in.Pattern)
	if err != nil {
		return ToolExecResult{Output: "Invalid glob pattern: " + err.Error(), IsError: true}
	}

	type hit struct {
		rel   string
		mtime int64
	}
	var hits []hit
	const maxHits = 500
	truncated := false
	foreign := paths.ForeignMounts(searchDir)

	_ = filepath.WalkDir(searchDir, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if p != searchDir {
			if foreign[p] {
				return filepath.SkipDir
			}
			name := d.Name()
			if d.IsDir() {
				if name == ".git" || name == "node_modules" || name == ".dart_tool" || (!in.Hidden && strings.HasPrefix(name, ".")) {
					return filepath.SkipDir
				}
				return nil
			}
			if !in.Hidden && strings.HasPrefix(name, ".") {
				return nil
			}
		} else if d.IsDir() {
			return nil
		}

		rel, err := filepath.Rel(searchDir, p)
		if err != nil {
			return nil
		}
		slashRel := filepath.ToSlash(rel)
		if re.MatchString(slashRel) || re.MatchString(d.Name()) {
			var mt int64
			if info, iErr := d.Info(); iErr == nil {
				mt = info.ModTime().UnixNano()
			}
			dispRel := slashRel
			if searchDir != tc.absWorkdir {
				if wRel, rErr := filepath.Rel(tc.absWorkdir, p); rErr == nil && !strings.HasPrefix(wRel, "..") {
					dispRel = filepath.ToSlash(wRel)
				} else {
					dispRel = p
				}
			}
			hits = append(hits, hit{rel: dispRel, mtime: mt})
			if len(hits) >= maxHits {
				truncated = true
				return fs.SkipAll
			}
		}
		return nil
	})

	sort.Slice(hits, func(i, j int) bool {
		if hits[i].mtime != hits[j].mtime {
			return hits[i].mtime > hits[j].mtime
		}
		return hits[i].rel < hits[j].rel
	})

	if len(hits) == 0 {
		return ToolExecResult{Output: "No files matched pattern: " + in.Pattern}
	}
	lines := make([]string, len(hits))
	for i, h := range hits {
		lines[i] = h.rel
	}
	out := strings.Join(lines, "\n")
	if truncated {
		out += fmt.Sprintf("\n\n(Results capped at %d files. Narrow your pattern or path.)", maxHits)
	}
	return ToolExecResult{Output: out, Metadata: map[string]any{"count": len(hits)}}
}

func globToRegex(pat string) (*regexp.Regexp, error) {
	pat = filepath.ToSlash(strings.TrimSpace(pat))
	pat = strings.TrimPrefix(pat, "./")
	var b strings.Builder
	b.WriteString("^")
	// If pattern contains no slash, allow matching anywhere in tree like OpenCode / ripgrep
	if !strings.Contains(pat, "/") {
		b.WriteString("(?:.+/)?")
	}
	for i := 0; i < len(pat); i++ {
		c := pat[i]
		switch c {
		case '*':
			if i+1 < len(pat) && pat[i+1] == '*' {
				i++
				if i+1 < len(pat) && pat[i+1] == '/' {
					i++
					b.WriteString("(?:.*/)?")
				} else {
					b.WriteString(".*")
				}
			} else {
				b.WriteString("[^/]*")
			}
		case '?':
			b.WriteString("[^/]")
		case '.', '+', '(', ')', '|', '^', '$', '[', ']':
			b.WriteByte('\\')
			b.WriteByte(c)
		case '{':
			end := strings.IndexByte(pat[i:], '}')
			if end > 1 {
				alts := strings.Split(pat[i+1:i+end], ",")
				for k := range alts {
					alts[k] = regexp.QuoteMeta(alts[k])
				}
				b.WriteString("(?:" + strings.Join(alts, "|") + ")")
				i += end
			} else {
				b.WriteString("\\{")
			}
		default:
			b.WriteByte(c)
		}
	}
	b.WriteString("$")
	return regexp.Compile(b.String())
}

func execGrepTool(ctx context.Context, tc toolContext, rawInput json.RawMessage) ToolExecResult {
	var in struct {
		Pattern string `json:"pattern"`
		Path    string `json:"path"`
		Include string `json:"include"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid grep arguments: " + err.Error(), IsError: true}
	}
	if in.Pattern == "" {
		return ToolExecResult{Output: "pattern must not be empty", IsError: true}
	}
	searchTarget, _, err := resolveToolPath(tc, in.Path, true)
	if err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	// Prefer ripgrep (`rg`) when installed on server, otherwise fall back to pure-Go regex walk.
	if rgPath, lookErr := exec.LookPath("rg"); lookErr == nil {
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		args := []string{"-n", "--no-heading", "--color=never", "--max-count=100", "--max-columns=300", "--max-filesize=2M"}
		if in.Include != "" {
			args = append(args, "--glob", in.Include)
		}
		args = append(args, "--", in.Pattern, searchTarget)
		cmd := exec.CommandContext(cctx, rgPath, args...)
		cmd.Dir = tc.absWorkdir
		out, runErr := cmd.Output()
		if runErr == nil || len(out) > 0 {
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			if len(lines) > 250 {
				lines = append(lines[:250], fmt.Sprintf("... (%d more matches omitted)", len(lines)-250))
			}
			// Relativize paths to absWorkdir for clean output
			prefix := strings.TrimSuffix(tc.absWorkdir, "/") + "/"
			for i := range lines {
				lines[i] = strings.TrimPrefix(lines[i], prefix)
			}
			return ToolExecResult{Output: strings.Join(lines, "\n")}
		}
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) && exitErr.ExitCode() == 1 {
			return ToolExecResult{Output: "No matches found."}
		}
	}

	re, err := regexp.Compile(in.Pattern)
	if err != nil {
		re, _ = regexp.Compile(regexp.QuoteMeta(in.Pattern))
	}
	var incRe *regexp.Regexp
	if in.Include != "" {
		incRe, _ = globToRegex(in.Include)
	}

	var matches []string
	const maxMatches = 200
	foreign := paths.ForeignMounts(searchTarget)

	_ = filepath.WalkDir(searchTarget, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || ctx.Err() != nil {
			return ctx.Err()
		}
		if d.IsDir() {
			if p != searchTarget && foreign[p] {
				return filepath.SkipDir
			}
			nm := d.Name()
			if nm == ".git" || nm == "node_modules" || nm == ".dart_tool" || nm == "build" {
				return filepath.SkipDir
			}
			return nil
		}
		if incRe != nil && !incRe.MatchString(d.Name()) {
			return nil
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() > 2*1024*1024 {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil || bytes.IndexByte(b[:minInt(len(b), 4096)], 0) >= 0 {
			return nil
		}
		disp := p
		if rel, rErr := filepath.Rel(tc.absWorkdir, p); rErr == nil && !strings.HasPrefix(rel, "..") {
			disp = filepath.ToSlash(rel)
		}
		for idx, line := range strings.Split(string(b), "\n") {
			if re.MatchString(line) {
				trimmed := strings.TrimRight(line, "\r")
				if len(trimmed) > 300 {
					trimmed = trimmed[:300] + "…"
				}
				matches = append(matches, fmt.Sprintf("%s:%d:%s", disp, idx+1, trimmed))
				if len(matches) >= maxMatches {
					return fs.SkipAll
				}
			}
		}
		return nil
	})

	if len(matches) == 0 {
		return ToolExecResult{Output: "No matches found."}
	}
	out := strings.Join(matches, "\n")
	if len(matches) >= maxMatches {
		out += fmt.Sprintf("\n\n(Results capped at %d matches. Refine pattern or path.)", maxMatches)
	}
	return ToolExecResult{Output: out, Metadata: map[string]any{"matches": len(matches)}}
}

func execShellTool(ctx context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	var in struct {
		Command string `json:"command"`
		Workdir string `json:"workdir"`
		Timeout int    `json:"timeout"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid shell arguments: " + err.Error(), IsError: true}
	}
	cmdStr := strings.TrimSpace(in.Command)
	if cmdStr == "" {
		return ToolExecResult{Output: "command must not be empty", IsError: true}
	}

	cwd := tc.absWorkdir
	if in.Workdir != "" {
		resolved, _, err := resolveToolPath(tc, in.Workdir, false)
		if err != nil {
			return ToolExecResult{Output: err.Error(), IsError: true}
		}
		cwd = resolved
	}

	if err := checkPerm("shell", cmdStr, map[string]any{"workdir": cwd}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	timeoutMS := in.Timeout
	if timeoutMS <= 0 {
		timeoutMS = 120_000
	}
	if timeoutMS > 600_000 {
		timeoutMS = 600_000
	}
	cctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()

	shellBin := "/bin/bash"
	if _, err := os.Stat(shellBin); err != nil {
		shellBin = "sh"
	}
	cmd := exec.Command(shellBin, "-c", cmdStr)
	cmd.Dir = cwd
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	env := append(os.Environ(),
		"AGENT=1",
		"OPENCODE=1",
		"AI_AGENT=opencode",
		"OPENCODE_SESSION_ID="+tc.session.ID,
		"GIT_TERMINAL_PROMPT=0",
		"DEBIAN_FRONTEND=noninteractive",
	)
	if tc.provider.UseProxy && tc.env.Proxy != nil {
		for k, v := range tc.env.Proxy() {
			if k != "" && v != "" {
				env = append(env, k+"="+v)
			}
		}
	}
	cmd.Env = env

	// Cap in-memory capture at 2 MiB to prevent runaway output OOM; TruncateOutput spills up to that cleanly.
	buf := &cappedBuffer{max: 2 * 1024 * 1024}
	cmd.Stdout = buf
	cmd.Stderr = buf

	if err := cmd.Start(); err != nil {
		return ToolExecResult{Output: "Failed to start command: " + err.Error(), IsError: true}
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.shell", map[string]any{"session": tc.session.ID, "cwd": cwd, "command": cmdStr})
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	var waitErr error
	timedOut := false
	select {
	case waitErr = <-done:
	case <-cctx.Done():
		timedOut = ctx.Err() == nil
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			select {
			case waitErr = <-done:
			case <-time.After(500 * time.Millisecond):
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				waitErr = <-done
			}
		}
	}

	out := strings.TrimRight(buf.String(), "\n")
	exitCode := 0
	if waitErr != nil {
		var ee *exec.ExitError
		if errors.As(waitErr, &ee) {
			exitCode = ee.ExitCode()
		} else {
			exitCode = -1
		}
	}

	if timedOut {
		if out != "" {
			out += "\n\n"
		}
		out += fmt.Sprintf("[Command timed out after %d ms and was terminated]", timeoutMS)
		return ToolExecResult{
			Output:   out,
			IsError:  true,
			Metadata: map[string]any{"exit": exitCode, "timeout": true},
		}
	}
	if ctx.Err() != nil {
		if out != "" {
			out += "\n\n"
		}
		out += "[Command interrupted by user]"
		return ToolExecResult{
			Output:   out,
			IsError:  true,
			Metadata: map[string]any{"interrupted": true},
		}
	}

	if exitCode != 0 {
		if out == "" {
			out = fmt.Sprintf("Command exited with code %d", exitCode)
		} else {
			out += fmt.Sprintf("\n\n[Exit code: %d]", exitCode)
		}
		return ToolExecResult{
			Output:   out,
			IsError:  false, // Non-zero exit is normal diagnostic feedback for tests/grep/git diff
			Metadata: map[string]any{"exit": exitCode},
		}
	}
	if out == "" {
		out = "(Command completed with exit code 0 and no output)"
	}
	return ToolExecResult{
		Output:   out,
		Metadata: map[string]any{"exit": 0},
	}
}

type cappedBuffer struct {
	buf bytes.Buffer
	max int
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	origLen := len(p)
	rem := c.max - c.buf.Len()
	if rem > 0 {
		if len(p) > rem {
			p = p[:rem]
		}
		_, _ = c.buf.Write(p)
	}
	return origLen, nil
}

func (c *cappedBuffer) String() string { return c.buf.String() }

func execTodoWriteTool(tc toolContext, rawInput json.RawMessage) ToolExecResult {
	var in struct {
		Todos []TodoItem `json:"todos"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid todowrite arguments: " + err.Error(), IsError: true}
	}
	for i := range in.Todos {
		if in.Todos[i].ID == "" {
			in.Todos[i].ID = fmt.Sprintf("%d", i+1)
		}
		if in.Todos[i].Status == "" {
			in.Todos[i].Status = "pending"
		}
		if in.Todos[i].Priority == "" {
			in.Todos[i].Priority = "medium"
		}
	}
	tc.env.updateTodos(tc.session.ID, in.Todos)

	completed := 0
	for _, td := range in.Todos {
		if td.Status == "completed" {
			completed++
		}
	}
	b, _ := json.MarshalIndent(in.Todos, "", "  ")
	return ToolExecResult{
		Output:   fmt.Sprintf("Updated todo list (%d/%d completed):\n%s", completed, len(in.Todos), string(b)),
		Metadata: map[string]any{"todos": in.Todos},
	}
}

func execSubagentTool(ctx context.Context, tc toolContext, rawInput json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	if tc.depth >= 1 {
		return ToolExecResult{Output: "Subagent depth limit reached (1): subagents cannot spawn nested subagents.", IsError: true}
	}
	var in struct {
		Agent       string `json:"agent"`
		Description string `json:"description"`
		Prompt      string `json:"prompt"`
	}
	if err := json.Unmarshal(rawInput, &in); err != nil {
		return ToolExecResult{Output: "Invalid subagent arguments: " + err.Error(), IsError: true}
	}
	subAgent := strings.ToLower(strings.TrimSpace(in.Agent))
	if subAgent != "explore" && subAgent != "general" {
		subAgent = "explore"
	}
	if tc.session.Agent == "plan" {
		subAgent = "explore" // Plan mode subagents are strictly read-only
	}
	if err := checkPerm("subagent", subAgent, map[string]any{"description": in.Description}); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}

	report, childID, err := tc.env.runChildSubagent(ctx, tc.session, tc.provider, subAgent, in.Description, in.Prompt, tc.depth+1)
	if err != nil {
		return ToolExecResult{Output: "Subagent failed: " + err.Error(), IsError: true}
	}
	return ToolExecResult{
		Output:   fmt.Sprintf("<subagent session_id=%q agent=%q>\n%s\n</subagent>", childID, subAgent, report),
		Metadata: map[string]any{"child_session_id": childID, "agent": subAgent, "description": in.Description},
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
