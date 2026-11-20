package statecrypt

import (
	"errors"
	"os/user"
	"path/filepath"

	"golang.org/x/sys/windows"
)

func ordinaryDir(dir string) error {
	p, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return err
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_DIRECTORY == 0 || attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return errors.New("状态目录不是普通目录或包含重解析点")
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return err
	}
	if rel, err := filepath.Rel(real, dir); err != nil || rel != "." {
		return errors.New("拒绝经重解析点访问状态目录")
	}
	return nil
}

// LockWriter holds a non-shareable handle for the agent lifetime, independent
// of the network listener. Process death releases it without journal replay.
func LockWriter(dir string) (func(), error) {
	return openWriterLock(dir, true)
}

func openWriterLock(dir string, create bool) (func(), error) {
	if err := ordinaryDir(dir); err != nil {
		return nil, err
	}
	p, err := windows.UTF16PtrFromString(filepath.Join(dir, WriterFile))
	if err != nil {
		return nil, err
	}
	disposition := uint32(windows.OPEN_EXISTING)
	if create {
		disposition = windows.OPEN_ALWAYS
	}
	f, err := windows.CreateFile(p, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
		disposition, windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	var fi windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(f, &fi); err != nil ||
		fi.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 || fi.NumberOfLinks != 1 {
		_ = windows.CloseHandle(f)
		return nil, errors.New("无法验证状态目录写入锁")
	}
	return func() { _ = windows.CloseHandle(f) }, nil
}

// ReplaceFile publishes a fully written file on the same volume.
func ReplaceFile(stage, final string) error {
	return moveFile(stage, final, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

func PublishDirectory(stage, final string) error {
	return moveFile(stage, final, windows.MOVEFILE_WRITE_THROUGH)
}

func moveFile(stage, final string, flags uint32) error {
	from, err := windows.UTF16PtrFromString(stage)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(final)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(from, to, flags)
}

func PrivateDirectory(dir string) error {
	if err := ordinaryDir(dir); err != nil {
		return err
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

// Windows file writes and publication use FlushFileBuffers and
// MOVEFILE_WRITE_THROUGH; a separate fsync of a directory is unavailable here.
func FlushDirectory(string) error { return nil }
