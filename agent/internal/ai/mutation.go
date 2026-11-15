//go:build linux || windows

package ai

import (
	"bytes"
	"fmt"
	"os"
	"sync"
	"unicode/utf8"
)

// Serialize file-tool commits, but never hold the lock while awaiting a user.
var toolMutationMu sync.Mutex

type fileOriginal struct {
	path   string
	data   []byte
	mode   os.FileMode
	exists bool
}

func captureTextFile(path string, allowMissing bool) (fileOriginal, error) {
	o := fileOriginal{path: path, mode: 0644}
	st, err := os.Lstat(path)
	if os.IsNotExist(err) && allowMissing {
		return o, nil
	}
	if err != nil {
		return o, err
	}
	if !st.Mode().IsRegular() {
		return o, fmt.Errorf("expected a regular text file: %s", path)
	}
	o.data, err = readToolFile(path, 8<<20)
	if err != nil {
		return o, err
	}
	if bytes.IndexByte(o.data, 0) >= 0 || !utf8.Valid(o.data) {
		return o, fmt.Errorf("binary or non-UTF-8 target: %s", path)
	}
	o.exists, o.mode = true, st.Mode().Perm()
	return o, nil
}

func (o fileOriginal) revalidate(tc toolContext) error {
	resolved, _, err := resolveToolPath(tc, o.path, false)
	if err != nil || resolved != o.path {
		return fmt.Errorf("path changed during approval: %s; read it again", o.path)
	}
	if !o.exists {
		if _, err := os.Lstat(o.path); !os.IsNotExist(err) {
			return fmt.Errorf("destination appeared during approval: %s; read it again", o.path)
		}
		return nil
	}
	current, err := captureTextFile(o.path, false)
	if err != nil || current.mode != o.mode || !bytes.Equal(current.data, o.data) {
		return fmt.Errorf("file changed during approval: %s; read it again", o.path)
	}
	return nil
}
