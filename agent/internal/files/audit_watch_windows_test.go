package files

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"testing"
	"time"
)

type auditEntry struct {
	name string
	size int64
	time time.Time
}

func (e auditEntry) Name() string               { return e.name }
func (e auditEntry) Size() int64                { return e.size }
func (e auditEntry) ModTime() time.Time         { return e.time }
func (e auditEntry) Mode() fs.FileMode          { return 0o644 }
func (e auditEntry) Type() fs.FileMode          { return 0 }
func (e auditEntry) IsDir() bool                { return false }
func (e auditEntry) Sys() any                   { return nil }
func (e auditEntry) Info() (fs.FileInfo, error) { return e, nil }

// Exact pre-audit algorithm. DirEntry.Info is deliberately a stable fixture:
// this measures signature construction separately from filesystem latency.
func legacyWatchSignature(entries []fs.DirEntry) string {
	signature := ""
	for _, ent := range entries {
		fi, err := ent.Info()
		if err == nil {
			signature += fmt.Sprintf("%s:%d:%d;", ent.Name(), fi.Size(), fi.ModTime().UnixNano())
		}
	}
	return signature
}

func BenchmarkAuditWatchSignature(b *testing.B) {
	for _, count := range []int{1000, 5000} {
		entries := make([]fs.DirEntry, count)
		for i := range entries {
			entries[i] = auditEntry{fmt.Sprintf("source_file_%04d.dart", i), int64(i * 123), time.Unix(1700000000, int64(i))}
		}
		b.Run(fmt.Sprintf("entries_%d", count), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if watchSignature(entries) == "" {
					b.Fatal("empty signature")
				}
			}
		})
	}
}

func TestWatchSignatureTracksTheSameMetadata(t *testing.T) {
	for _, entries := range [][]fs.DirEntry{
		nil,
		{auditEntry{"a.txt", 10, time.Unix(100, 7)}},
		{auditEntry{"中文:;.txt", 20, time.Unix(100, 8)}, auditEntry{"b", 0, time.Unix(0, 0)}},
	} {
		want := sha256.Sum256([]byte(legacyWatchSignature(entries)))
		if watchSignature(entries) != string(want[:]) {
			t.Fatal("directory change detection lost metadata")
		}
	}
}
