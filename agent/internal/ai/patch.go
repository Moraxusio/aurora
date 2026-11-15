//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

var patchToolDef = ToolDef{
	Name: "apply_patch",
	Description: `Apply related text-file changes in one patch. All paths, exact hunks and permissions are checked before writing; a failed commit restores already changed files.
Format:
*** Begin Patch
*** Add File: path
+new line
*** Update File: path
@@
 unchanged context
-old line
+new line
*** Delete File: path
*** End Patch
For a rename, put "*** Move to: new-path" directly after Update File. Use unique exact context. Prefix every content line with space, - or +. Optional "*** End of File" anchors the last hunk. Paths are relative to the working directory or absolute inside the configured root. Add/move refuse to overwrite an existing destination.`,
	Parameters: map[string]any{
		"type":       "object",
		"properties": map[string]any{"patch": map[string]any{"type": "string", "description": "Complete patch, including Begin/End Patch markers"}},
		"required":   []string{"patch"},
	},
}

type patchHunk struct {
	before, after []string
	end           bool
}
type patchFile struct {
	action, path, move string
	add                []string
	hunks              []patchHunk
}

func parsePatch(text string) ([]patchFile, error) {
	if len(text) > 2<<20 {
		return nil, fmt.Errorf("patch exceeds 2 MiB")
	}
	lines := strings.Split(strings.TrimSuffix(strings.ReplaceAll(text, "\r\n", "\n"), "\n"), "\n")
	if len(lines) < 3 || lines[0] != "*** Begin Patch" || lines[len(lines)-1] != "*** End Patch" {
		return nil, fmt.Errorf("patch must have exact Begin Patch and End Patch markers")
	}
	var files []patchFile
	for i := 1; i < len(lines)-1; {
		var f patchFile
		for _, action := range []string{"Add", "Update", "Delete"} {
			if p, ok := strings.CutPrefix(lines[i], "*** "+action+" File: "); ok {
				f.action, f.path = action, strings.TrimSpace(p)
				break
			}
		}
		if f.path == "" {
			return nil, fmt.Errorf("expected file header at patch line %d", i+1)
		}
		i++
		if f.action == "Update" && i < len(lines)-1 && strings.HasPrefix(lines[i], "*** Move to: ") {
			f.move = strings.TrimSpace(strings.TrimPrefix(lines[i], "*** Move to: "))
			if f.move == "" {
				return nil, fmt.Errorf("move destination is empty")
			}
			i++
		}
		for i < len(lines)-1 && !strings.HasPrefix(lines[i], "*** ") {
			if f.action == "Add" {
				if !strings.HasPrefix(lines[i], "+") {
					return nil, fmt.Errorf("added lines must start with + (line %d)", i+1)
				}
				f.add = append(f.add, lines[i][1:])
				i++
				continue
			}
			if f.action != "Update" || !(lines[i] == "@@" || strings.HasPrefix(lines[i], "@@ ")) {
				return nil, fmt.Errorf("expected @@ hunk at patch line %d", i+1)
			}
			i++
			h := patchHunk{}
			for i < len(lines)-1 && lines[i] != "@@" && !strings.HasPrefix(lines[i], "@@ ") && !strings.HasPrefix(lines[i], "*** ") {
				line := lines[i]
				if len(line) == 0 || !strings.ContainsRune(" +-", rune(line[0])) {
					return nil, fmt.Errorf("invalid hunk line %d; prefix content with space, - or +", i+1)
				}
				if line[0] != '+' {
					h.before = append(h.before, line[1:])
				}
				if line[0] != '-' {
					h.after = append(h.after, line[1:])
				}
				i++
			}
			if i < len(lines)-1 && lines[i] == "*** End of File" {
				h.end = true
				i++
			}
			if len(h.before) == 0 {
				return nil, fmt.Errorf("update hunks need existing context")
			}
			f.hunks = append(f.hunks, h)
		}
		if f.action == "Update" && len(f.hunks) == 0 && f.move == "" {
			return nil, fmt.Errorf("empty update for %s", f.path)
		}
		files = append(files, f)
		if len(files) > 64 {
			return nil, fmt.Errorf("patch exceeds 64 files")
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("patch contains no files")
	}
	return files, nil
}

func applyPatchHunks(original string, hunks []patchHunk) (string, error) {
	eol := "\n"
	if strings.Contains(original, "\r\n") {
		eol = "\r\n"
	}
	text := strings.ReplaceAll(original, "\r\n", "\n")
	trailing := strings.HasSuffix(text, "\n")
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	cursor := 0
	for _, h := range hunks {
		match := -1
		for i := cursor; i+len(h.before) <= len(lines); i++ {
			if h.end && i+len(h.before) != len(lines) {
				continue
			}
			equal := true
			for j, line := range h.before {
				equal = equal && lines[i+j] == line
			}
			if equal {
				if match != -1 {
					return "", fmt.Errorf("hunk context is ambiguous; include more unchanged lines")
				}
				match = i
			}
		}
		if match < 0 {
			return "", fmt.Errorf("hunk context does not match; read the file again")
		}
		tail := append([]string(nil), lines[match+len(h.before):]...)
		lines = append(append(lines[:match:match], h.after...), tail...)
		cursor = match + len(h.after)
	}
	result := strings.Join(lines, eol)
	if trailing {
		result += eol
	}
	return result, nil
}

func execPatchTool(ctx context.Context, tc toolContext, raw json.RawMessage, checkPerm func(string, string, map[string]any) error) ToolExecResult {
	fail := func(err error) ToolExecResult { return ToolExecResult{Output: err.Error(), IsError: true} }
	var in struct {
		Patch string `json:"patch"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return fail(err)
	}
	files, err := parsePatch(in.Patch)
	if err != nil {
		return fail(err)
	}
	type change struct {
		file                            patchFile
		src, dest, display, destDisplay string
		after                           []byte
		diff                            FileDiff
		mode                            os.FileMode
	}
	var changes []change
	var originals []fileOriginal
	seen := map[string]bool{}
	capture := func(path string, mustExist bool) (fileOriginal, error) {
		key := path
		if runtime.GOOS == "windows" {
			key = strings.ToLower(key)
		}
		if seen[key] {
			return fileOriginal{}, fmt.Errorf("duplicate patch target %s", path)
		}
		seen[key] = true
		o, err := captureTextFile(path, !mustExist)
		if err != nil {
			return o, err
		}
		if !mustExist && o.exists {
			return o, fmt.Errorf("destination already exists: %s", path)
		}
		originals = append(originals, o)
		return o, nil
	}
	for _, file := range files {
		src, display, err := resolveToolPath(tc, file.path, false)
		if err != nil {
			return fail(err)
		}
		o, err := capture(src, file.action != "Add")
		if err != nil {
			return fail(err)
		}
		c := change{file: file, src: src, dest: src, display: display, destDisplay: display, mode: o.mode}
		switch file.action {
		case "Add":
			if len(file.add) > 0 {
				c.after = []byte(strings.Join(file.add, "\n") + "\n")
			}
		case "Update":
			next, err := applyPatchHunks(string(o.data), file.hunks)
			if err != nil {
				return fail(fmt.Errorf("%s: %w", display, err))
			}
			c.after = []byte(next)
			if file.move != "" {
				c.dest, c.destDisplay, err = resolveToolPath(tc, file.move, false)
				if err != nil {
					return fail(err)
				}
				if _, err = capture(c.dest, false); err != nil {
					return fail(err)
				}
			}
		}
		c.diff = ComputeFileDiff(display, string(o.data), string(c.after))
		if file.action == "Add" {
			c.diff.Status = "added"
		}
		if file.action == "Delete" || c.dest != c.src {
			c.diff = ComputeFileDiff(display, string(o.data), "")
			c.diff.Status = "deleted"
		}
		changes = append(changes, c)
	}
	// Ask before holding the mutation lock; verify originals again afterwards.
	for _, c := range changes {
		action := "edit"
		if c.file.action == "Add" {
			action = "write"
		}
		if err := checkPerm(action, c.display, map[string]any{"diff": c.diff}); err != nil {
			return fail(err)
		}
		if c.dest != c.src {
			if err := checkPerm("write", c.destDisplay, map[string]any{"source": c.display, "diff": ComputeFileDiff(c.destDisplay, "", string(c.after))}); err != nil {
				return fail(err)
			}
		}
	}
	toolMutationMu.Lock()
	defer toolMutationMu.Unlock()
	for _, c := range changes {
		src, _, err := resolveToolPath(tc, c.file.path, false)
		if err != nil || src != c.src {
			return fail(fmt.Errorf("patch path changed during approval: %s", c.file.path))
		}
		if c.file.move != "" {
			dest, _, err := resolveToolPath(tc, c.file.move, false)
			if err != nil || dest != c.dest {
				return fail(fmt.Errorf("patch move destination changed during approval: %s", c.file.move))
			}
		}
	}
	for _, o := range originals {
		if err := o.revalidate(tc); err != nil {
			return fail(err)
		}
	}
	touched := map[string]bool{}
	rollback := func(cause error) ToolExecResult {
		var failures []string
		for i := len(originals) - 1; i >= 0; i-- {
			o := originals[i]
			if !touched[o.path] {
				continue
			}
			var err error
			if o.exists {
				err = atomicWriteFile(o.path, o.data, o.mode)
			} else {
				err = os.Remove(o.path)
				if os.IsNotExist(err) {
					err = nil
				}
			}
			if err != nil {
				failures = append(failures, o.path+": "+err.Error())
			}
		}
		if len(failures) > 0 {
			return fail(fmt.Errorf("patch failed: %v; rollback needs attention: %s", cause, strings.Join(failures, "; ")))
		}
		return fail(fmt.Errorf("patch failed and file changes were restored: %w", cause))
	}
	if err := ctx.Err(); err != nil {
		return fail(err)
	}
	var diffs []FileDiff
	for _, c := range changes {
		if err := ctx.Err(); err != nil {
			return rollback(err)
		}
		if c.file.action != "Delete" {
			if err := os.MkdirAll(filepath.Dir(c.dest), 0755); err != nil {
				return rollback(err)
			}
			if err := atomicWriteFile(c.dest, c.after, c.mode); err != nil {
				return rollback(err)
			}
			touched[c.dest] = true
		}
		if c.file.action == "Delete" || c.dest != c.src {
			if err := os.Remove(c.src); err != nil {
				return rollback(err)
			}
			touched[c.src] = true
		}
		diffs = append(diffs, c.diff)
		if c.dest != c.src {
			diffs = append(diffs, ComputeFileDiff(c.destDisplay, "", string(c.after)))
		}
	}
	if tc.env.Audit != nil {
		tc.env.Audit.Write("ai.patch", map[string]any{"session": tc.session.ID, "files": len(changes)})
	}
	return ToolExecResult{Output: fmt.Sprintf("Applied patch to %d file(s).", len(changes)), Metadata: map[string]any{"files": diffs}}
}
