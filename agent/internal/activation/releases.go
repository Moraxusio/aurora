//go:build linux || windows

package activation

import (
	"crypto/sha256"
	"debug/elf"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"aurora3/internal/statecrypt"
	"aurora3/internal/update"
)

// LinuxProgram verifies an immutable candidate from the isolated release set.
// Policy is read on every selection so a revoked binary is never auto-started.
func LinuxProgram(root string, p Program, channel string) (string, error) {
	if !valid(p) {
		return "", errors.New("无效程序选择")
	}
	policyDir, err := statecrypt.OpenStateDir(filepath.Join(root, "policy"))
	if err != nil {
		return "", err
	}
	defer policyDir.Close()
	rules, err := statecrypt.ReadRegular(policyDir, "policy.json", 1<<20)
	if err != nil {
		return "", err
	}
	policySig, err := statecrypt.ReadRegular(policyDir, "policy.sig", 4096)
	if err != nil {
		return "", err
	}
	policy, err := update.VerifyPolicy(rules, policySig)
	if err != nil {
		return "", err
	}
	if err := policy.TargetRefusal(p.Version); err != nil {
		return "", err
	}
	programs, err := statecrypt.OpenStateDir(filepath.Join(root, "programs", p.SHA256))
	if err != nil {
		return "", err
	}
	defer programs.Close()
	raw, err := statecrypt.ReadRegular(programs, "manifest.json", 64<<10)
	if err != nil {
		return "", err
	}
	sig, err := statecrypt.ReadRegular(programs, "manifest.sig", 4096)
	if err != nil {
		return "", err
	}
	m, err := update.VerifyFor(update.ProductAgent, channel, raw, sig)
	if err != nil {
		return "", err
	}
	if m.Version != p.Version || !strings.EqualFold(m.SHA256, p.SHA256) || !filepath.IsLocal(m.File) {
		return "", errors.New("已签名程序与版本选择不符")
	}
	info, err := programs.Lstat(m.File)
	if err != nil || !info.Mode().IsRegular() || info.Size() != m.Size {
		return "", errors.New("程序不存在或不是完整的普通文件")
	}
	file, err := programs.Open(m.File)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(opened, info) {
		return "", errors.New("程序文件在打开时已变化")
	}
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(file, m.Size+1))
	if err != nil || n != m.Size || hex.EncodeToString(hash.Sum(nil)) != p.SHA256 {
		return "", errors.New("程序内容与签名清单不符")
	}
	image, err := elf.NewFile(file)
	if err != nil {
		return "", errors.New("已签名产物不是 Linux ELF")
	}
	defer image.Close()
	want := map[string]elf.Machine{"amd64": elf.EM_X86_64, "arm64": elf.EM_AARCH64}
	machine, supported := want[runtime.GOARCH]
	if !supported || image.Machine != machine || (image.Type != elf.ET_EXEC && image.Type != elf.ET_DYN) {
		return "", errors.New("已签名 ELF 架构不符或不可执行")
	}
	return filepath.Join(programs.Name(), m.File), nil
}
