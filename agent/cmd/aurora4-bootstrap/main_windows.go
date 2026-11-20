package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

var Version = "dev"
var PublicPreview = "0" // set by the public prerelease packaging command

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		if len(os.Args) == 1 {
			msg, _ := windows.UTF16PtrFromString(err.Error())
			title, _ := windows.UTF16PtrFromString("Aurora 4")
			_, _ = windows.MessageBox(0, msg, title, windows.MB_ICONERROR)
		}
		os.Exit(1)
	}
}

func run(args []string) error {
	arg := ""
	if len(args) == 1 {
		arg = args[0]
	}
	if len(args) > 1 || (arg != "" && arg != "--version" && arg != "--verify" && arg != "--prepare-only") {
		return errors.New("使用方法：Aurora.exe [--version | --verify | --prepare-only]")
	}
	if arg == "--version" {
		fmt.Println(Version)
		return nil
	}
	bundle, id, err := openBundle(payloadBytes, manifestBytes, signatureBytes, Version)
	if err != nil || arg == "--verify" {
		return err
	}
	base, err := windows.KnownFolderPath(windows.FOLDERID_LocalAppData, 0)
	if err != nil {
		return err
	}
	if fi, err := os.Lstat(base); err != nil || !fi.IsDir() || linkLike(base, fi) {
		return errors.New("Windows 用户本地数据目录不是普通目录")
	}
	runtimeDir := filepath.Join(base, "Aurora4Runtime")
	if err := privateDirectory(runtimeDir); err != nil {
		return err
	}
	versions := filepath.Join(runtimeDir, "versions")
	if err := privateDirectory(versions); err != nil {
		return err
	}
	unlock, err := lockRuntime(runtimeDir)
	if err != nil {
		return err
	}
	defer unlock()

	// If a damaged cache directory cannot be moved because an old process
	// is still using it, keep it intact and use a fresh, verified generation.
	dest := filepath.Join(versions, id)
	for i := 1; ; i++ {
		fi, err := os.Lstat(dest)
		if errors.Is(err, os.ErrNotExist) {
			stage, err := os.MkdirTemp(versions, ".staged-")
			if err != nil {
				return err
			}
			defer os.RemoveAll(stage)
			if err := unpackRuntime(bundle, stage); err != nil {
				return err
			}
			if err := verifyRuntime(bundle, stage, linkLike); err != nil {
				return err
			}
			if err := moveNew(stage, dest); err != nil {
				return err
			}
			break
		}
		if err != nil {
			return err
		}
		if fi.IsDir() && !linkLike(dest, fi) && verifyRuntime(bundle, dest, linkLike) == nil {
			break
		}
		if i >= 16 {
			return errors.New("已保留损坏的运行缓存；请退出全部 Aurora 进程并检查运行目录")
		}
		dest = filepath.Join(versions, fmt.Sprintf("%s-repair%d", id, i))
	}
	if arg == "--prepare-only" {
		fmt.Println(dest)
		return nil
	}

	// Early compatibility candidate: do not allow an unqualified launch to
	// migrate a user's production profile before encrypted migration exists.
	profile := filepath.Join(base, "Aurora4ProtectedPreviewState")
	scope := "aurora4-protected-preview"
	if PublicPreview == "1" {
		profile = filepath.Join(base, "Aurora4PublicPreviewState")
		scope = "aurora4-public-preview"
	}
	if err := privateDirectory(profile); err != nil {
		return err
	}
	cmd := exec.Command(filepath.Join(dest, "aurora.exe"))
	cmd.Dir = dest
	cmd.Env = cleanEnvironment(os.Environ(), map[string]string{
		"LOCALAPPDATA":            profile,
		"AURORA3_INSTANCE_SCOPE":  scope,
		"AURORA4_PROTECTED_STATE": "1",
		"AURORA4_PUBLIC_PREVIEW":  PublicPreview,
		"AURORA3_AGENT_DIR":       filepath.Join(dest, "agent"),
		"AURORA3_LOCAL_AGENT_DIR": filepath.Join(dest, "local-agent", "windows-amd64"),
	})
	return cmd.Start()
}

func cleanEnvironment(input []string, pinned map[string]string) []string {
	out := make([]string, 0, len(input)+len(pinned))
	for _, entry := range input {
		k, _, _ := strings.Cut(entry, "=")
		k = strings.ToUpper(k)
		if _, overridden := pinned[k]; overridden || k == "AURORA3_TRUST_KEY" ||
			k == "AURORA_RELEASE_KEY" {
			continue
		}
		out = append(out, entry)
	}
	for k, v := range pinned {
		out = append(out, k+"="+v)
	}
	return out
}

func linkLike(path string, fi fs.FileInfo) bool {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil || fi.Mode()&os.ModeSymlink != 0 {
		return true
	}
	attr, err := windows.GetFileAttributes(p)
	return err != nil || attr&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

func privateDirectory(dir string) error {
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return err
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() || linkLike(dir, fi) {
		return errors.New("拒绝非普通目录或重解析点：" + dir)
	}
	u, err := user.Current()
	if err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + u.Uid + ")")
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}

func lockRuntime(dir string) (func(), error) {
	path := filepath.Join(dir, ".bootstrap.lock")
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_ALWAYS,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil ||
		info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		windows.CloseHandle(handle)
		return nil, errors.New("启动锁不是普通文件")
	}
	var offset windows.Overlapped
	if err := windows.LockFileEx(handle, windows.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &offset); err != nil {
		windows.CloseHandle(handle)
		return nil, err
	}
	return func() {
		_ = windows.UnlockFileEx(handle, 0, 1, 0, &offset)
		_ = windows.CloseHandle(handle)
	}, nil
}

func moveNew(old, new string) error {
	from, err := windows.UTF16PtrFromString(old)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(new)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(from, to, windows.MOVEFILE_WRITE_THROUGH)
}
