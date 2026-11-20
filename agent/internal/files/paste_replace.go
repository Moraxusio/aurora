//go:build linux || windows

package files

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"aurora3/internal/filetxn"
	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

const replacementReceipts = "paste-receipts"
const maxReplacementReceipts = 16384
const maxReceiptBytes = 64 << 10

type replaceRequest struct {
	Root      string `json:"root"`
	Path      string `json:"path"`
	ToRoot    string `json:"to_root"`
	To        string `json:"to"`
	IfMatch   string `json:"if_match"`
	ToIfMatch string `json:"to_if_match"`
	ID        string `json:"id"`
}

type replaceReceipt struct {
	Request   replaceRequest `json:"request"`
	Committed bool           `json:"committed"`
}

func validReceiptID(id string) bool {
	_, err := hex.DecodeString(id)
	return len(id) == 32 && strings.ToLower(id) == id && err == nil
}

func readReceipt(root *os.Root, name string) (replaceReceipt, error) {
	var r replaceReceipt
	limit := int64(maxReceiptBytes + statecrypt.Overhead)
	fi, err := root.Lstat(name)
	if err != nil {
		return r, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > limit {
		return r, errors.New("替换收据不是有效的普通文件")
	}
	f, err := root.Open(name)
	if err != nil {
		return r, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(fi, opened) {
		return r, errors.New("替换收据在打开时已变化")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return r, err
	}
	defer clear(data)
	if int64(len(data)) > limit {
		return r, errors.New("替换收据超过大小上限")
	}
	if codec := statecrypt.Current(); codec != nil || statecrypt.Protected(data) {
		plain, err := codec.Open("paste-receipt:"+filepath.Base(name), data)
		if err != nil {
			return r, err
		}
		defer clear(plain)
		data = plain
	}
	if len(data) > maxReceiptBytes || json.Unmarshal(data, &r) != nil || !r.Committed ||
		r.Request.ID+".json" != filepath.Base(name) {
		return replaceReceipt{}, errors.New("替换收据损坏或与操作编号不匹配")
	}
	return r, nil
}

// Copy-replace is deliberately limited to regular files within the existing
// durable transaction budget. Neither disconnect nor restart needs to move
// a hidden backup back into place. Deleting a cut source is a separate,
// version-checked action only after the client learns the copy committed.
func (e *Env) fsPasteReplace(ctx context.Context, raw json.RawMessage) (any, error) {
	var a replaceRequest
	if json.Unmarshal(raw, &a) != nil || !validReceiptID(a.ID) || a.IfMatch == "" || a.ToIfMatch == "" || e.StateDir == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "替换需要操作编号、源版本和目标版本")
	}
	src, err := cleanRel(a.Path)
	if err != nil {
		return nil, err
	}
	dst, err := cleanRel(a.To)
	if err != nil {
		return nil, err
	}
	if src == "." || validName(dst) != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "不能替换根目录或使用无效名称")
	}
	filetxn.CommitMu.Lock()
	defer filetxn.CommitMu.Unlock()
	if err := filetxn.CheckReady(); err != nil {
		return nil, err
	}
	state, err := os.OpenRoot(e.StateDir)
	if err != nil {
		return nil, fsErr(err)
	}
	defer state.Close()
	name := filepath.Join(replacementReceipts, a.ID+".json")
	if r, err := readReceipt(state, name); err == nil {
		if r.Request != a || !r.Committed {
			return nil, wire.Errf(wire.CodeConflict, "操作编号已使用")
		}
		return r, nil
	} else if !os.IsNotExist(err) {
		return nil, fsErr(err)
	}
	if err := state.Mkdir(replacementReceipts, 0o700); err != nil && !os.IsExist(err) {
		return nil, fsErr(err)
	}
	dir, err := state.Open(replacementReceipts)
	if err != nil {
		return nil, fsErr(err)
	}
	names, readErr := dir.Readdirnames(maxReplacementReceipts)
	dir.Close()
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		return nil, fsErr(readErr)
	}
	if len(names) >= maxReplacementReceipts {
		return nil, wire.Errf(wire.CodeConflict, "替换收据存储已满，请联系管理员归档旧收据")
	}
	source, err := e.openRoot(a.Root)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	target, err := e.openRoot(a.ToRoot)
	if err != nil {
		return nil, err
	}
	defer target.Close()
	sourceInfo, err := source.Lstat(src)
	if err != nil {
		return nil, fsErr(err)
	}
	targetInfo, err := target.Lstat(dst)
	if err != nil {
		return nil, fsErr(err)
	}
	if os.SameFile(sourceInfo, targetInfo) || !sourceInfo.Mode().IsRegular() || !targetInfo.Mode().IsRegular() ||
		sourceInfo.Size() > filetxn.MaxFileBytes || targetInfo.Size() > filetxn.MaxFileBytes {
		return nil, wire.Errf(wire.CodeConflict, "仅支持替换两个不同的普通文件（每个最多 64 MiB）；请选择保留两者")
	}
	readVersion := func(root *os.Root, name, version string, info os.FileInfo) (filetxn.State, error) {
		if etag(info) != version {
			return filetxn.State{}, wire.Errf(wire.CodeConflict, "文件已变化，请刷新后重新确认")
		}
		result, err := filetxn.Read(root, name)
		if err != nil {
			return result, fsErr(err)
		}
		if current, err := root.Lstat(name); err != nil || etag(current) != version || !os.SameFile(current, info) {
			return result, wire.Errf(wire.CodeConflict, "读取期间文件已变化，请刷新后重新确认")
		}
		return result, nil
	}
	after, err := readVersion(source, src, a.IfMatch, sourceInfo)
	if err != nil {
		return nil, err
	}
	before, err := readVersion(target, dst, a.ToIfMatch, targetInfo)
	if err != nil {
		return nil, err
	}
	r := replaceReceipt{Request: a, Committed: true}
	data, err := json.Marshal(r)
	if err != nil || len(data) > maxReceiptBytes {
		return nil, wire.Errf(wire.CodeBadRequest, "替换请求超出收据大小上限")
	}
	defer clear(data)
	if codec := statecrypt.Current(); codec != nil {
		data, err = codec.Seal("paste-receipt:"+filepath.Base(name), data)
		if err != nil {
			return nil, fsErr(err)
		}
	}
	rootDir := rootPath(e, a.ToRoot)
	// The existing destination retains its permissions and owner.
	after.Mode = before.Mode
	changes := []filetxn.Change{
		{Root: rootDir, Path: filepath.FromSlash(dst), Before: before, After: after},
		{Root: e.StateDir, Path: name, After: filetxn.State{Exists: true, Data: data, Mode: 0o600}},
	}
	roots := make([]string, 0, len(e.Roots))
	for _, root := range e.Roots {
		roots = append(roots, root.Path)
	}
	if err := filetxn.New(e.StateDir, roots).CommitLocked(ctx, changes); err != nil {
		if errors.Is(err, filetxn.ErrConflict) {
			return nil, wire.Errf(wire.CodeConflict, "替换期间文件已变化，请刷新后重新确认")
		}
		return nil, fsErr(err)
	}
	e.Audit.Write("fs.paste.replace", map[string]any{"root": a.ToRoot, "path": a.To, "id": a.ID})
	return r, nil
}

func (e *Env) fsPasteStatus(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(raw, &a) != nil || !validReceiptID(a.ID) || e.StateDir == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "无效的操作编号")
	}
	// A receipt can be on disk before its commit marker. Wait for the
	// transaction, and never confirm success when recovery is still required.
	filetxn.CommitMu.Lock()
	defer filetxn.CommitMu.Unlock()
	if err := filetxn.CheckReady(); err != nil {
		return nil, err
	}
	state, err := os.OpenRoot(e.StateDir)
	if err != nil {
		return nil, fsErr(err)
	}
	defer state.Close()
	r, err := readReceipt(state, filepath.Join(replacementReceipts, a.ID+".json"))
	if err != nil {
		return nil, fsErr(err)
	}
	return r, nil
}
