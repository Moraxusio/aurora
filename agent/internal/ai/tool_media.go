//go:build linux || windows

package ai

import (
	"fmt"
	"io"
	"os"
	"strings"
)

func readToolFile(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > limit {
		return nil, fmt.Errorf("expected a regular file of at most %d bytes", limit)
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("file grew beyond the %d byte read limit", limit)
	}
	return b, err
}

func toolMediaResult(tc toolContext, display, name string, data []byte) ToolExecResult {
	fail := func(err error) ToolExecResult { return ToolExecResult{Output: err.Error(), IsError: true} }
	mime, err := attachmentMime(data)
	if err != nil {
		return fail(err)
	}
	key, kind := "pdf_input", "file"
	if strings.HasPrefix(mime, "image/") {
		key, kind = "image_input", "image"
	}
	if !tc.provider.allows(key) {
		return fail(fmt.Errorf("%s is disabled for the current model. File %s has not been presented to the model; do not claim to have inspected its contents", key, display))
	}
	if tc.env.StateDir == "" {
		return fail(fmt.Errorf("media reads require an agent attachment store"))
	}
	// Capture immutable bytes now; session JSON and events carry references.
	attachmentStoreMu.Lock()
	defer attachmentStoreMu.Unlock()
	dir := tc.env.attachmentDir()
	if err := checkAttachmentBudget(dir, int64(len(data))); err != nil {
		return fail(err)
	}
	meta, err := saveAttachment(dir, name, mime, data)
	if err != nil {
		return fail(err)
	}
	return ToolExecResult{
		Output:      fmt.Sprintf("Read %s (%s, %d bytes). The captured file is attached as model input.", display, mime, len(data)),
		Metadata:    map[string]any{"path": display, "mime": mime, "size": len(data)},
		Attachments: []Part{{Type: kind, ID: NewID("prt"), AttachmentID: meta.ID, Mime: mime, Filename: name, Size: int64(len(data))}},
	}
}
