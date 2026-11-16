package files

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"aurora3/internal/filetxn"
	"aurora3/internal/wire"
)

type batchItem struct {
	Root     string  `json:"root"`
	Path     string  `json:"path"`
	IfMatch  string  `json:"if_match"`
	Create   bool    `json:"create"`
	Delete   bool    `json:"delete"`
	Size     int     `json:"size"`               // Incoming bytes, before optional text encoding.
	Encoding string  `json:"encoding,omitempty"` // absent means exact raw bytes
	ModeBits *uint32 `json:"modeBits,omitempty"`
}

// A staged stream followed by one shared recoverable transaction. No commit
// lock is held while waiting for network data, and all targets are revalidated.
func (e *Env) fsCommit(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var args struct {
		Changes []batchItem `json:"changes"`
	}
	if err := decode(raw, &args); err != nil {
		return err
	}
	if len(args.Changes) == 0 || len(args.Changes) > 128 {
		return wire.Errf(wire.CodeBadRequest, "批量文件修改必须包含 1–128 个文件")
	}
	release, err := e.acquireTextOperation()
	if err != nil {
		return err
	}
	defer release()
	changes := make([]filetxn.Change, 0, len(args.Changes))
	roots := map[string]*os.Root{}
	defer func() {
		for _, root := range roots {
			root.Close()
		}
	}()
	rootPaths := []string{}
	seen := map[string]bool{}
	total := 0
	admit := func() error {
		filetxn.CommitMu.Lock()
		defer filetxn.CommitMu.Unlock()
		if err := filetxn.CheckReady(); err != nil {
			return err
		}
		for _, item := range args.Changes {
			if item.Size < 0 || item.Size > filetxn.MaxFileBytes ||
				(item.ModeBits != nil && *item.ModeBits > 0o777) ||
				(item.Delete && (item.Size != 0 || item.Create)) ||
				(!item.Create && item.IfMatch == "") {
				return wire.Errf(wire.CodeBadRequest, "每项必须指定有效大小和预期版本，或声明创建新文件")
			}
			total += item.Size
			if total > filetxn.MaxTransactionBytes {
				return wire.Errf(wire.CodeBadRequest, "批量修改超过 %d MiB", filetxn.MaxTransactionBytes>>20)
			}
			if item.Encoding != "" {
				if _, _, err := textEncoding(item.Encoding); err != nil {
					return wire.Errf(wire.CodeBadRequest, "%v", err)
				}
			}
			rel, err := cleanRel(item.Path)
			if err != nil {
				return err
			}
			if err := validName(rel); err != nil {
				return err
			}
			root := roots[item.Root]
			if root == nil {
				root, err = e.openRoot(item.Root)
				if err != nil {
					return err
				}
				roots[item.Root] = root
			}
			rootPath, err := filepath.EvalSymlinks(rootPath(e, item.Root))
			if err != nil {
				return err
			}
			// Resolve existing parent aliases for duplicate detection; os.Root
			// remains the boundary for reading/writing the actual files.
			parent, err := existingParentIdentity(filepath.Join(rootPath, filepath.Dir(filepath.FromSlash(rel))))
			if err != nil {
				return fsErr(err)
			}
			identity := filepath.Join(parent, filepath.Base(filepath.FromSlash(rel)))
			if runtime.GOOS == "windows" {
				identity = strings.ToLower(identity)
			}
			if seen[identity] {
				return wire.Errf(wire.CodeBadRequest, "批量修改包含重复目标")
			}
			seen[identity] = true
			if err := checkBatchTarget(root, rel, item); err != nil {
				return err
			}
			before, err := filetxn.Read(root, filepath.FromSlash(rel))
			if err != nil {
				return fsErr(err)
			}
			if err := checkBatchTarget(root, rel, item); err != nil {
				return err
			}
			total += len(before.Data)
			if total > filetxn.MaxTransactionBytes {
				return wire.Errf(wire.CodeBadRequest, "批量修改超过 %d MiB", filetxn.MaxTransactionBytes>>20)
			}
			after := filetxn.State{Exists: !item.Delete, Mode: before.Mode, UID: before.UID, GID: before.GID}
			if after.Mode == 0 {
				after.Mode = 0o644
			}
			if item.ModeBits != nil {
				after.Mode = os.FileMode(*item.ModeBits)
			}
			rootPaths = append(rootPaths, rootPath)
			changes = append(changes, filetxn.Change{Root: rootPath, Path: filepath.FromSlash(rel), Before: before, After: after})
		}
		return nil
	}
	if err := admit(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"ready": true})); err != nil {
		return err
	}
	for i, item := range args.Changes {
		data := make([]byte, 0, item.Size)
		for len(data) < item.Size {
			_ = st.SetReadDeadline(time.Now().Add(30 * time.Second))
			typ, payload, err := wire.ReadFrame(st)
			if err != nil {
				return err
			}
			if typ != wire.TypeData || len(payload) == 0 || len(payload) > item.Size-len(data) {
				return wire.Errf(wire.CodeBadRequest, "批量文件内容长度与声明不符")
			}
			data = append(data, payload...)
		}
		if item.Encoding != "" && !item.Delete {
			encoded, err := encodeText(data, item.Encoding)
			if err != nil {
				return wire.Errf(wire.CodeBadRequest, "%v", err)
			}
			total += len(encoded) - len(data)
			data = encoded
			if len(data) > filetxn.MaxFileBytes || total > filetxn.MaxTransactionBytes {
				return wire.Errf(wire.CodeBadRequest, "编码后的文件超过事务预算")
			}
		}
		changes[i].After.Data = data
	}
	_ = st.SetReadDeadline(time.Now().Add(30 * time.Second))
	typ, _, err := wire.ReadFrame(st)
	if err != nil {
		return err
	}
	if typ != wire.TypeEnd {
		return wire.Errf(wire.CodeBadRequest, "缺少批量提交结束帧")
	}
	_ = st.SetReadDeadline(time.Time{})
	// After receipt, a reset still cancels a commit that has not completed.
	inputDone := make(chan struct{})
	go func() { defer close(inputDone); _, _, _ = wire.ReadFrame(st); cancel() }()
	defer func() { cancel(); st.Close(); <-inputDone }()
	result, err := func() ([]map[string]any, error) {
		filetxn.CommitMu.Lock()
		defer filetxn.CommitMu.Unlock()
		if err := filetxn.New(e.StateDir, rootPaths).CommitLocked(ctx, changes); err != nil {
			if errors.Is(err, filetxn.ErrConflict) {
				err = wire.Errf(wire.CodeConflict, "文件已变化，整批修改未提交")
			}
			return nil, err
		}
		result := make([]map[string]any, 0, len(changes))
		for i, change := range changes {
			item, root := args.Changes[i], roots[args.Changes[i].Root]
			value := map[string]any{"root": item.Root, "path": item.Path, "deleted": item.Delete}
			// Never acknowledge a newer writer's etag as our submitted text.
			// Agent writes share the lock; external writes require byte and
			// identity checks around capturing the returned version.
			info, statErr := root.Lstat(change.Path)
			if item.Delete {
				if !os.IsNotExist(statErr) {
					return nil, wire.Errf(wire.CodeConflict, "提交后文件再次变化，请核对磁盘")
				}
			} else {
				state, readErr := filetxn.Read(root, change.Path)
				after, afterErr := root.Lstat(change.Path)
				if statErr != nil || readErr != nil || afterErr != nil ||
					!os.SameFile(info, after) || etag(info) != etag(after) || !bytes.Equal(state.Data, change.After.Data) {
					return nil, wire.Errf(wire.CodeConflict, "提交后文件再次变化，请核对磁盘")
				}
				value["etag"], value["size"] = etag(after), after.Size()
				value["modeBits"] = uint32(after.Mode().Perm())
			}
			result = append(result, value)
		}
		return result, nil
	}()
	if err != nil {
		return wire.WriteJSON(st, wire.ErrResponse(err))
	}
	if e.Audit != nil {
		e.Audit.Write("fs.commit", map[string]any{"files": len(changes), "bytes": total})
	}
	_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
	return wire.WriteJSON(st, wire.OKResponse(map[string]any{"files": result}))
}

// A transaction may create files below new directories. Resolve aliases in the
// nearest existing parent without creating anything during admission.
func existingParentIdentity(path string) (string, error) {
	var suffix []string
	for {
		resolved, err := filepath.EvalSymlinks(path)
		if err == nil {
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return resolved, nil
		}
		if !os.IsNotExist(err) || filepath.Dir(path) == path {
			return "", err
		}
		suffix = append(suffix, filepath.Base(path))
		path = filepath.Dir(path)
	}
}

func checkBatchTarget(root *os.Root, rel string, item batchItem) error {
	if item.Create && item.IfMatch == "" {
		if _, err := root.Lstat(rel); os.IsNotExist(err) {
			// Check every existing ancestor through os.Root. The transaction
			// creates absent directories only after all versions are validated.
			for parent := filepath.Dir(rel); ; parent = filepath.Dir(parent) {
				info, err := root.Stat(parent)
				if err == nil {
					if !info.IsDir() {
						return wire.Errf(wire.CodeConflict, "上级路径不是目录")
					}
					return nil
				}
				if !os.IsNotExist(err) || parent == "." {
					return fsErr(err)
				}
			}
		}
	}
	_, err := checkTarget(root, rel, &fsArgs{IfMatch: item.IfMatch, Create: item.Create})
	return err
}
