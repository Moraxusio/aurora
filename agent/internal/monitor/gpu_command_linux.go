package monitor

import (
	"context"
	"os/exec"
)

func gpuCommand(ctx context.Context) (*exec.Cmd, error) {
	exe, err := exec.LookPath("nvidia-smi")
	if err != nil {
		return nil, err
	}
	return exec.CommandContext(ctx, exe, "-q", "-x"), nil
}
