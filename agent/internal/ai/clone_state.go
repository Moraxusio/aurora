//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"aurora3/internal/statecrypt"
)

// CloneLegacyStore reads the 3.x store without starting AI, recovering file
// transactions, or refreshing an index in the source. Snapshot sources are
// read through Git but only encrypted records are written to the clone.
func CloneLegacyStore(source, stage string, codec *statecrypt.Codec, workspaces CloneWorkspaces) error {
	root, err := statecrypt.OpenStateDir(filepath.Join(source, "ai"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer root.Close()
	dirs, err := os.ReadDir(root.Name())
	if err != nil {
		return err
	}
	for _, directory := range dirs {
		name := directory.Name()
		if !directory.IsDir() {
			return fmt.Errorf("无法迁移未知 AI 记录：%s", name)
		}
		switch name {
		case "sessions", "attachments", "snapshots", "tool-output":
		default:
			return fmt.Errorf("无法迁移未知 AI 目录：%s", name)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	importer := &snapshotImport{ctx: ctx, source: NewSnapshotManager(source), stage: stage, final: workspaces.Final,
		codec: codec, workspaces: workspaces, repos: map[string]bool{}, objects: map[string]map[string]string{},
		writers: map[string]func(string, []byte, int64) (string, error){}}
	spills, err := cloneToolOutput(source, stage, workspaces.Final, codec)
	if err != nil {
		return err
	}
	if err := cloneSessions(source, stage, codec, importer, spills); err != nil {
		return err
	}
	// A known repository can hold unreachable objects from old runs. Keep
	// those only in the unchanged source; never omit an unidentified repository.
	old := importer.source.BaseDir
	repositories, err := os.ReadDir(old)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, repo := range repositories {
		if !repo.IsDir() || !importer.repos[filepath.Join(old, repo.Name())] {
			return errors.New("存在无法关联至会话的旧快照仓库；已保留源并拒绝迁移")
		}
	}
	return cloneAttachments(source, stage, codec)
}

func cloneSessions(source, stage string, codec *statecrypt.Codec, importer *snapshotImport, spills map[string]string) error {
	legacy := filepath.Join(source, "ai", "sessions")
	items, err := os.ReadDir(legacy)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if r, err := statecrypt.OpenStateDir(legacy); err != nil {
		return err
	} else {
		r.Close()
	}
	dest := filepath.Join(stage, "ai", "sessions")
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return err
	}
	ids := map[string]bool{}
	for _, item := range items {
		ext := filepath.Ext(item.Name())
		id := strings.TrimSuffix(item.Name(), ext)
		if !item.Type().IsRegular() || !sessionIDPattern.MatchString(id) || (ext != ".json" && ext != ".journal" && ext != ".index") {
			return fmt.Errorf("存在未知会话记录、备份或待恢复日志：%s", item.Name())
		}
		ids[id] = true
	}
	if len(ids) > 10000 {
		return errors.New("会话数超过克隆上限")
	}
	for id := range ids {
		session, rec, err := readSessionDisk(legacy, id)
		if err != nil || rec.torn >= 0 {
			return fmt.Errorf("无法完整读取旧会话 %s，原记录未改动", id)
		}
		if len(rec.index.Trees) != 0 {
			if err := importer.migrate(session); err != nil {
				return fmt.Errorf("会话 %s 的快照未能迁移：%w", id, err)
			}
		}
		legacyEnv := &Env{StateDir: source}
		for _, attachment := range rec.index.Attachments {
			if _, err := legacyEnv.attachmentMeta(attachment); err != nil {
				return fmt.Errorf("会话 %s 的附件引用无法校验：%w", id, err)
			}
		}
		rebindToolOutput(session, spills)
		b, err := json.Marshal(sessionCheckpoint{Session: *session, Revision: rec.revision})
		if err != nil {
			return err
		}
		if len(b) > sessionBytesMax-statecrypt.Overhead {
			clear(b)
			return errors.New("迁移后的会话超过存储限额")
		}
		err = writeClonedRecord(codec, "checkpoint", filepath.Join(dest, id+".json"), b)
		clear(b)
		if err != nil {
			return err
		}
	}
	return nil
}

func cloneToolOutput(source, stage, final string, codec *statecrypt.Codec) (map[string]string, error) {
	name := filepath.Join("ai", "tool-output")
	root, err := statecrypt.OpenStateDir(filepath.Join(source, name))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer root.Close()
	entries, err := os.ReadDir(root.Name())
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	if len(entries) == 0 {
		return out, nil
	}
	if !filepath.IsAbs(final) || len(entries) > 20000 {
		return nil, errors.New("旧工具输出目录超出迁移限制")
	}
	d := filepath.Join(stage, name)
	if err := os.MkdirAll(d, 0o700); err != nil {
		return nil, err
	}
	var used int64
	for _, ent := range entries {
		if !ent.Type().IsRegular() || !spillName.MatchString(ent.Name()) {
			return nil, errors.New("旧工具输出包含未知文件")
		}
		data, err := statecrypt.ReadRegular(root, ent.Name(), maxSpillBytes)
		if err != nil {
			return nil, err
		}
		used += int64(len(data) + statecrypt.Overhead)
		if used > 512<<20 {
			clear(data)
			return nil, errors.New("工具输出超过克隆存储预算")
		}
		err = writeClonedRecord(codec, "tool-output", filepath.Join(d, ent.Name()), data)
		clear(data)
		if err != nil {
			return nil, err
		}
		out[filepath.Join(root.Name(), ent.Name())] = filepath.Join(final, name, ent.Name())
	}
	return out, nil
}

func rebindToolOutput(session *Session, mapping map[string]string) {
	const hint = "Full output saved to: "
	for _, m := range session.Messages {
		for i := range m.Parts {
			p := &m.Parts[i]
			if p.Type != "tool-result" {
				continue
			}
			if raw, ok := p.Metadata["saved_path"].(string); ok {
				if path := mapping[raw]; path != "" {
					p.Metadata["saved_path"] = path
				}
			}
			idx := strings.Index(p.Output, hint)
			if idx < 0 {
				continue
			}
			start := idx + len(hint)
			old, _, ok := strings.Cut(p.Output[start:], "\n")
			if path := mapping[old]; ok && path != "" {
				p.Output = p.Output[:start] + path + p.Output[start+len(old):]
			}
		}
	}
}

func cloneAttachments(source, stage string, codec *statecrypt.Codec) error {
	legacy, target := (&Env{StateDir: source}).attachmentDir(), (&Env{StateDir: stage}).attachmentDir()
	items, err := os.ReadDir(legacy)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if r, err := statecrypt.OpenStateDir(legacy); err != nil {
		return err
	} else {
		r.Close()
	}
	if err := os.MkdirAll(target, 0o700); err != nil {
		return err
	}
	pairs := map[string]int{}
	for _, item := range items {
		ext := filepath.Ext(item.Name())
		id := strings.TrimSuffix(item.Name(), ext)
		if !item.Type().IsRegular() || !attachmentIDPattern.MatchString(id) || (ext != ".bin" && ext != ".json") {
			return fmt.Errorf("未知附件记录或待恢复上传：%s", item.Name())
		}
		pairs[id]++
	}
	e := &Env{StateDir: source}
	var used int64
	for id, count := range pairs {
		if count != 2 {
			return fmt.Errorf("附件 %s 不完整", id)
		}
		m, err := e.attachmentMeta(id)
		if err != nil {
			return err
		}
		used += m.Size + attachmentMetaMax + int64(2*statecrypt.Overhead)
		if used > 512<<20 {
			return errors.New("加密附件超过存储限额")
		}
		body, err := e.loadAttachment(Part{AttachmentID: id})
		if err != nil {
			return err
		}
		err = writeClonedRecord(codec, "attachment-data", filepath.Join(target, id+".bin"), body)
		clear(body)
		if err != nil {
			return err
		}
		b, err := json.Marshal(m)
		if err != nil {
			return err
		}
		err = writeClonedRecord(codec, "attachment-meta", filepath.Join(target, id+".json"), b)
		clear(b)
		if err != nil {
			return err
		}
	}
	return nil
}

func writeClonedRecord(codec *statecrypt.Codec, scope, path string, plain []byte) error {
	record, err := codec.Seal("ai:"+scope+":"+filepath.Base(path), plain)
	if err != nil {
		return err
	}
	return atomicWriteFile(path, record, 0o600)
}
