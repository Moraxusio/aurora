package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"aurora3/internal/update"
)

const runtimeProduct = "aurora4-runtime"
const maxRuntimeBytes = 768 << 20
const maxRuntimeFiles = 16000

func openBundle(payload, manifest, signature []byte, version string) (*zip.Reader, string, error) {
	m, err := update.VerifyFor(runtimeProduct, update.ChannelStable, manifest, signature)
	if err != nil {
		return nil, "", err
	}
	if m.Version != version || m.File != runtimeProduct+"-"+version+"-windows-amd64.exe" ||
		m.Size != int64(len(payload)) || m.SHA256 != update.HashBytes(payload) {
		return nil, "", errors.New("签名清单与内置 Windows 运行包不匹配")
	}
	z, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return nil, "", err
	}
	if err := validateArchive(z); err != nil {
		return nil, "", err
	}
	return z, m.Version + "-" + m.SHA256, nil
}

func validateArchive(z *zip.Reader) error {
	if len(z.File) == 0 || len(z.File) > maxRuntimeFiles {
		return errors.New("运行包条目数无效")
	}
	type entry struct {
		name string
		dir  bool
	}
	paths := map[string]entry{}
	files := map[string]bool{}
	var usage uint64
	for _, f := range z.File {
		isDir := f.FileInfo().IsDir()
		name := strings.TrimSuffix(f.Name, "/")
		mode := f.Mode()
		if !safeArchivePath(name) || (isDir && f.UncompressedSize64 != 0) || (!isDir && !mode.IsRegular()) {
			return fmt.Errorf("运行包有无效路径或文件类型：%q", f.Name)
		}
		key := strings.ToLower(name)
		if files[key] {
			return fmt.Errorf("运行包有重复路径：%q", f.Name)
		}
		files[key] = true
		parts := strings.Split(name, "/")
		for i := 1; i <= len(parts); i++ {
			p := strings.Join(parts[:i], "/")
			e := entry{p, i != len(parts) || isDir}
			if old, ok := paths[strings.ToLower(p)]; ok && old != e {
				return fmt.Errorf("运行包有大小写或目录冲突：%q", p)
			}
			paths[strings.ToLower(p)] = e
		}
		if f.UncompressedSize64 > maxRuntimeBytes-usage {
			return errors.New("运行包超过解包上限")
		}
		usage += f.UncompressedSize64
	}
	for _, required := range []string{"aurora.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
		"local-agent/windows-amd64/manifest.json", "agent/amd64/manifest.json"} {
		if !files[required] || paths[required] != (entry{required, false}) {
			return fmt.Errorf("运行包缺少 %s", required)
		}
	}
	return nil
}

func safeArchivePath(p string) bool {
	if !utf8.ValidString(p) || !fs.ValidPath(p) || p == "." || len(p) > 512 ||
		strings.ContainsAny(p, "\\:\x00<>\"|?*") {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if strings.TrimRight(part, " .") != part ||
			strings.IndexFunc(part, func(r rune) bool { return r < 32 }) != -1 {
			return false
		}
		base, _, _ := strings.Cut(strings.ToUpper(part), ".")
		base = strings.TrimRight(base, " ")
		switch base {
		case "CON", "CONIN$", "CONOUT$", "PRN", "AUX", "NUL":
			return false
		}
		if strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT") {
			if strings.Contains("1 2 3 4 5 6 7 8 9 ¹ ² ³", base[3:]) && len([]rune(base[3:])) == 1 {
				return false
			}
		}
	}
	return true
}

func unpackRuntime(z *zip.Reader, dir string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	for _, item := range z.File {
		name := filepath.FromSlash(strings.TrimSuffix(item.Name, "/"))
		if item.FileInfo().IsDir() {
			if err := root.MkdirAll(name, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := root.MkdirAll(filepath.Dir(name), 0o700); err != nil {
			return err
		}
		in, err := item.Open()
		if err != nil {
			return err
		}
		out, err := root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			in.Close()
			return err
		}
		n, err := io.Copy(out, io.LimitReader(in, int64(item.UncompressedSize64)+1))
		in.Close()
		if err == nil && n != int64(item.UncompressedSize64) {
			err = io.ErrUnexpectedEOF
		}
		if err == nil {
			err = out.Sync()
		}
		if closeErr := out.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return fmt.Errorf("解包 %s: %w", item.Name, err)
		}
	}
	return nil
}

// Verify the full cache against the signed archive, including refusing extra
// files: an extra DLL can change what a correctly hashed executable loads.
func verifyRuntime(z *zip.Reader, dir string, linkLike func(string, fs.FileInfo) bool) error {
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() || linkLike(dir, fi) {
		return errors.New("运行目录无效")
	}
	want := map[string]*zip.File{}
	dirs := map[string]bool{".": true}
	for _, item := range z.File {
		name := filepath.FromSlash(strings.TrimSuffix(item.Name, "/"))
		if item.FileInfo().IsDir() {
			dirs[name] = true
		} else {
			want[name] = item
		}
		for p := filepath.Dir(name); !dirs[p]; p = filepath.Dir(p) {
			dirs[p] = true
		}
	}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		if linkLike(p, fi) {
			return errors.New("运行目录包含链接或重解析点")
		}
		if d.IsDir() && dirs[rel] {
			return nil
		}
		item := want[rel]
		if item == nil || !d.Type().IsRegular() || uint64(fi.Size()) != item.UncompressedSize64 {
			return fmt.Errorf("运行目录有意外文件或大小不匹配：%s", rel)
		}
		in, err := item.Open()
		if err != nil {
			return err
		}
		expected, err := digest(in, int64(item.UncompressedSize64))
		in.Close()
		if err != nil {
			return err
		}
		actualFile, err := os.Open(p)
		if err != nil {
			return err
		}
		actual, err := digest(actualFile, fi.Size())
		actualFile.Close()
		if err != nil || actual != expected {
			return fmt.Errorf("运行文件校验失败：%s", rel)
		}
		delete(want, rel)
		return nil
	})
	if err == nil && len(want) != 0 {
		return errors.New("运行目录缺少签名文件")
	}
	return err
}

func digest(r io.Reader, size int64) ([32]byte, error) {
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(r, size+1))
	if err == nil && n != size {
		err = io.ErrUnexpectedEOF
	}
	return [32]byte(h.Sum(nil)), err
}
