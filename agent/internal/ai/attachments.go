//go:build linux || windows

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
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

const maxAttachmentBytes = 8 << 20

var attachmentIDPattern = regexp.MustCompile(`^att_[0-9a-f]{24}$`)
var attachmentStoreMu sync.Mutex

const attachmentMetaMax = 4096

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
	b, err := readAIRecord("attachment-meta", filepath.Join(e.attachmentDir(), id+".json"), attachmentMetaMax)
	if err != nil || json.Unmarshal(b, &m) != nil || m.ID != id || m.Size <= 0 || m.Size > maxAttachmentBytes {
		return m, errors.New("附件不存在或已损坏，请重新选择文件")
	}
	return m, nil
}
func (e *Env) loadAttachment(p Part) ([]byte, error) {
	m, err := e.attachmentMeta(p.AttachmentID)
	if err != nil {
		return nil, err
	}
	b, err := readAIRecord("attachment-data", filepath.Join(e.attachmentDir(), m.ID+".bin"), m.Size)
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

// checkAttachmentBudget and saveAttachment require attachmentStoreMu.
func checkAttachmentBudget(dir string, size int64) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return errors.New("无法创建附件存储目录")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var used int64
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			return err
		}
		used += info.Size()
	}
	// Reserve a bounded metadata record too, so committed files cannot exceed
	// the quota by one record on an otherwise full store.
	overhead := int64(attachmentMetaMax)
	if statecrypt.Current() != nil {
		overhead += int64(2 * statecrypt.Overhead)
	}
	if used+size+overhead > 512<<20 {
		return errors.New("AI 附件存储已达到 512 MiB 上限，拒绝继续上传以保护服务器磁盘")
	}
	return nil
}

func saveAttachment(dir, name, mime string, data []byte) (attachmentMeta, error) {
	id := NewID("att")
	sum := sha256.Sum256(data)
	m := attachmentMeta{ID: id, Name: name, Mime: mime, Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}
	meta, err := json.Marshal(m)
	if err != nil {
		return attachmentMeta{}, err
	}
	if len(meta) > attachmentMetaMax {
		return attachmentMeta{}, errors.New("附件元数据超过存储预算")
	}
	path := filepath.Join(dir, id+".bin")
	metaPath := filepath.Join(dir, id+".json")
	for _, name := range []string{path, metaPath} {
		if _, err := os.Lstat(name); !os.IsNotExist(err) {
			if err != nil {
				return attachmentMeta{}, err
			}
			return attachmentMeta{}, errors.New("已有同编号附件，拒绝覆盖")
		}
	}
	if err := writeAIRecord("attachment-data", path, data); err != nil {
		return attachmentMeta{}, err
	}
	if err := writeAIRecord("attachment-meta", metaPath, meta); err != nil {
		// The metadata is the publication record. An interrupted publication
		// can leave an orphan, but never a reference to partial data.
		_ = os.Remove(path)
		return attachmentMeta{}, err
	}
	return m, nil
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
	if err := checkAttachmentBudget(dir, in.Size); err != nil {
		return err
	}
	_ = st.SetDeadline(time.Now().Add(2 * time.Minute))
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return err
	}
	// Admission and the existing upload lock bound memory to one upload of
	// at most 8 MiB. Unverified upload plaintext is never staged on disk.
	data := make([]byte, int(in.Size))
	defer clear(data)
	var received int
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		typ, b, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ == wire.TypeEnd {
			if received != len(data) || len(b) != 0 {
				return errors.New("附件上传未完成")
			}
			break
		}
		if typ != wire.TypeData || len(b) > len(data)-received {
			return errors.New("附件大小或数据帧无效")
		}
		received += copy(data[received:], b)
	}
	mime, err := attachmentMime(data)
	if err != nil {
		return wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	name := filepath.Base(strings.ReplaceAll(in.Name, "\\", "/"))
	if name == "." || name == "/" || name == "" {
		name = "attachment"
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	m, err := saveAttachment(dir, name, mime, data)
	if err != nil {
		return err
	}
	meta, _ := json.Marshal(m)
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
func (e *Env) validateAttachments(atts []ContextAttachment, providers ...ProviderConfig) error {
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
			if len(providers) > 0 {
				if strings.HasPrefix(m.Mime, "image/") && !providers[0].allows("image_input") {
					return errors.New("当前模型已禁用图片输入，请调整模型能力或更换模型")
				}
				if m.Mime == "application/pdf" && !providers[0].allows("pdf_input") {
					return errors.New("当前模型已禁用 PDF 输入，请调整模型能力或更换模型")
				}
			}
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
	if e.validateSessionReferencesLocked() != nil {
		return
	}
	for _, r := range e.records {
		for _, id := range r.index.Attachments {
			delete(candidates, id)
		}
	}
	for _, session := range e.sessions {
		for _, item := range session.Inbox {
			for _, attachment := range item.Attachments {
				delete(candidates, attachment.AttachmentID)
			}
		}
		for _, message := range session.Messages {
			for _, part := range message.Parts {
				delete(candidates, part.AttachmentID)
				for _, attachment := range part.Attachments {
					delete(candidates, attachment.AttachmentID)
				}
			}
		}
	}
	for _, run := range e.running {
		for _, item := range run.inbox {
			for _, attachment := range item.Attachments {
				delete(candidates, attachment.AttachmentID)
			}
		}
		for _, item := range run.queued {
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
