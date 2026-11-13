//go:build linux

package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"aurora3/internal/wire"
)

const maxAttachmentBytes = 8 << 20

var attachmentIDPattern = regexp.MustCompile(`^att_[0-9a-f]{24}$`)
var attachmentStoreMu sync.Mutex

type attachmentMeta struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Mime   string `json:"mime"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

func (e *Env) attachmentDir() string { return filepath.Join(e.StateDir, "ai", "attachments") }
func (e *Env) attachmentMeta(id string) (attachmentMeta, error) {
	var m attachmentMeta
	if e.StateDir == "" || !attachmentIDPattern.MatchString(id) {
		return m, errors.New("附件引用无效，请重新选择文件")
	}
	f, err := os.Open(filepath.Join(e.attachmentDir(), id+".json"))
	if err != nil {
		return m, errors.New("附件不存在或已损坏，请重新选择文件")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil || len(b) > 4096 || json.Unmarshal(b, &m) != nil || m.ID != id || m.Size <= 0 || m.Size > maxAttachmentBytes {
		return m, errors.New("附件不存在或已损坏，请重新选择文件")
	}
	return m, nil
}
func (e *Env) loadAttachment(p Part) ([]byte, error) {
	m, err := e.attachmentMeta(p.AttachmentID)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(e.attachmentDir(), m.ID+".bin")
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() != m.Size {
		return nil, errors.New("附件数据不存在或已变化")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("无法读取附件")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxAttachmentBytes+1))
	if err != nil {
		return nil, errors.New("无法读取附件")
	}
	if int64(len(b)) != m.Size {
		return nil, errors.New("附件大小已变化，请重新上传")
	}
	h := sha256.Sum256(b)
	if hex.EncodeToString(h[:]) != m.SHA256 {
		return nil, errors.New("附件校验失败，请重新上传")
	}
	return b, nil
}
func attachmentMime(b []byte) (string, error) {
	m := http.DetectContentType(b)
	switch m {
	case "image/png", "image/jpeg", "image/gif":
		config, _, err := image.DecodeConfig(bytes.NewReader(b))
		if err != nil || config.Width <= 0 || config.Height <= 0 || int64(config.Width)*int64(config.Height) > 40_000_000 {
			return "", errors.New("图片无效或超过 4000 万像素，请缩小后再添加")
		}
		return m, nil
	case "image/webp", "application/pdf":
		return m, nil
	}
	if utf8.Valid(b) && !bytes.Contains(b, []byte{0}) {
		if len(b) > 256<<10 {
			return "", errors.New("文本附件超过 256 KiB，请选择较小文件")
		}
		return "text/plain", nil
	}
	return "", errors.New("不支持此二进制格式；支持图片、PDF 和 UTF-8 文本/代码，不会把二进制伪装成文本")
}
func (s svc) opAttachmentUpload(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var in struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return err
	}
	if in.Size <= 0 || in.Size > maxAttachmentBytes || len(in.Name) > 512 || s.StateDir == "" {
		return wire.Errf(wire.CodeBadRequest, "附件应为 1 字节至 8 MiB")
	}
	attachmentStoreMu.Lock()
	defer attachmentStoreMu.Unlock()
	dir := s.attachmentDir()
	if err := os.MkdirAll(dir, 0700); err != nil {
		return errors.New("无法创建附件存储目录")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var used int64
	for _, entry := range entries {
		if info, err := entry.Info(); err == nil {
			used += info.Size()
		}
	}
	// Reserve a bounded metadata record too, so committed files cannot exceed
	// the quota by one record on an otherwise full store.
	if used+in.Size+4096 > 512<<20 {
		return errors.New("AI 附件存储已达到 512 MiB 上限，拒绝继续上传以保护服务器磁盘")
	}
	f, err := os.CreateTemp(dir, ".upload-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	_ = f.Chmod(0600)
	_ = st.SetDeadline(time.Now().Add(2 * time.Minute))
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return err
	}
	var received int64
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		typ, b, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ == wire.TypeEnd {
			if received != in.Size || len(b) != 0 {
				return errors.New("附件上传未完成")
			}
			break
		}
		if typ != wire.TypeData || received+int64(len(b)) > in.Size {
			return errors.New("附件大小或数据帧无效")
		}
		if _, err := f.Write(b); err != nil {
			return err
		}
		received += int64(len(b))
	}
	if err := f.Close(); err != nil {
		return err
	}
	b, err := os.ReadFile(f.Name())
	if err != nil {
		return err
	}
	mime, err := attachmentMime(b)
	if err != nil {
		return wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	name := filepath.Base(strings.ReplaceAll(in.Name, "\\", "/"))
	if name == "." || name == "/" || name == "" {
		name = "attachment"
	}
	id := NewID("att")
	sum := sha256.Sum256(b)
	m := attachmentMeta{ID: id, Name: name, Mime: mime, Size: in.Size, SHA256: hex.EncodeToString(sum[:])}
	if err := os.Rename(f.Name(), filepath.Join(dir, id+".bin")); err != nil {
		return err
	}
	meta, _ := json.Marshal(m)
	if err := atomicWriteFile(filepath.Join(dir, id+".json"), meta, 0600); err != nil {
		_ = os.Remove(filepath.Join(dir, id+".bin"))
		return err
	}
	return wire.WriteJSON(st, wire.Response{OK: true, Result: meta})
}
func (s svc) opAttachmentDownload(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var in struct {
		ID string `json:"id"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return err
	}
	m, err := s.attachmentMeta(in.ID)
	if err != nil {
		return wire.Errf(wire.CodeNotFound, "%v", err)
	}
	b, err := s.loadAttachment(Part{AttachmentID: in.ID})
	if err != nil {
		return err
	}
	_ = st.SetWriteDeadline(time.Now().Add(2 * time.Minute))
	meta, _ := json.Marshal(m)
	if err := wire.WriteJSON(st, wire.Response{OK: true, Result: meta}); err != nil {
		return err
	}
	for start := 0; start < len(b); start += wire.DataChunk {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		end := start + wire.DataChunk
		if end > len(b) {
			end = len(b)
		}
		if err := wire.WriteFrame(st, wire.TypeData, b[start:end]); err != nil {
			return err
		}
	}
	return wire.WriteFrame(st, wire.TypeEnd, nil)
}
func (e *Env) validateAttachments(atts []ContextAttachment) error {
	if len(atts) > 8 {
		return errors.New("每条消息最多 8 个附件")
	}
	var total int64
	for _, a := range atts {
		if a.AttachmentID != "" {
			m, err := e.attachmentMeta(a.AttachmentID)
			if err != nil {
				return err
			}
			total += m.Size
		} else {
			total += int64(len(a.Content))
			if len(a.Content) > 256<<10 {
				return errors.New("内联文本附件过大，请使用分块上传")
			}
		}
	}
	if total > 20<<20 {
		return errors.New("每条消息附件总大小不能超过 20 MiB")
	}
	return nil
}
func (e *Env) userParts(text string, atts []ContextAttachment) []Part {
	parts := []Part{}
	if t := formatUserContent(text, atts); t != "" {
		parts = append(parts, Part{Type: "text", ID: NewID("prt"), Text: t})
	}
	for _, a := range atts {
		if a.AttachmentID != "" {
			m, err := e.attachmentMeta(a.AttachmentID)
			if err != nil {
				continue
			}
			typ := "file"
			if strings.HasPrefix(m.Mime, "image/") {
				typ = "image"
			}
			parts = append(parts, Part{Type: typ, ID: NewID("prt"), AttachmentID: m.ID, Mime: m.Mime, Filename: m.Name, Size: m.Size})
		}
	}
	return parts
}

// Called under e.mu when the user deletes a conversation. Only files belonging
// to attachments from the removed messages are candidates; shared references
// (including active steering inboxes) keep the data. Never touch workspace files.
func (e *Env) removeUnusedAttachmentsLocked(candidates map[string]bool) {
	for _, session := range e.sessions {
		for _, message := range session.Messages {
			for _, part := range message.Parts {
				delete(candidates, part.AttachmentID)
			}
		}
	}
	for _, run := range e.running {
		for _, item := range run.inbox {
			for _, attachment := range item.Attachments {
				delete(candidates, attachment.AttachmentID)
			}
		}
	}
	for id := range candidates {
		if !attachmentIDPattern.MatchString(id) {
			continue
		}
		_ = os.Remove(filepath.Join(e.attachmentDir(), id+".bin"))
		_ = os.Remove(filepath.Join(e.attachmentDir(), id+".json"))
	}
}
