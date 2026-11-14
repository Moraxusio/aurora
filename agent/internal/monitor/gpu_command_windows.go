package monitor

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func gpuCommand(ctx context.Context) (*exec.Cmd, error) {
	exe, err := exec.LookPath("nvidia-smi.exe")
	if err != nil {
		exe = filepath.Join(os.Getenv("ProgramFiles"), "NVIDIA Corporation", "NVSMI", "nvidia-smi.exe")
		if st, e := os.Stat(exe); e != nil || st.IsDir() {
			return nil, err
		}
	}
	cmd := exec.CommandContext(ctx, exe, "-q", "-x")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd, nil
}
