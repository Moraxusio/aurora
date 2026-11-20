package main

import (
	"errors"
	"flag"
	"fmt"
	"path/filepath"

	"aurora3/internal/ai"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	"aurora3/internal/statecrypt"
)

func cloneProtectedPreview(args []string) error {
	f := flag.NewFlagSet("clone-protected-preview", flag.ContinueOnError)
	source := f.String("legacy-config", "", "已停止的 3.x agent 的配置文件")
	dest := f.String("dest", "", "尚不存在的隔离验收目录")
	instance := f.String("instance", "", "新具名验收实例")
	stopped := f.Bool("source-stopped", false, "确认源 agent 已停止")
	if err := f.Parse(args); err != nil {
		return err
	}
	if !*stopped || f.NArg() != 0 || !filepath.IsAbs(*source) || *dest == "" || *instance == "" {
		return errors.New("必须显式指定 --legacy-config、--dest、--instance 并确认 --source-stopped")
	}
	cfg, err := entry.LoadConfig(*source)
	if err != nil {
		return err
	}
	var pin string
	if err := statecrypt.CloneDirectory(cfg.StateDir, *dest, func(stage string, names []string) error {
		if err := entry.CheckLegacyCloneNames(cfg.StateDir, names, false); err != nil {
			return err
		}
		codec, fingerprint, err := entry.CloneLinuxIdentity(cfg, stage, *dest, *instance)
		if err != nil {
			return err
		}
		pin = fingerprint
		workspaces := ai.CloneWorkspaces{Final: *dest}
		for _, root := range cfg.Roots {
			workspaces.Legacy = append(workspaces.Legacy, ai.Root{ID: root.ID, Path: root.Path})
		}
		for _, root := range entry.IsolatedCloneRoots(cfg.Roots, *dest) {
			workspaces.Target = append(workspaces.Target, ai.Root{ID: root.ID, Path: root.Path})
		}
		if err := ai.CloneLegacyStore(cfg.StateDir, stage, codec, workspaces); err != nil {
			return err
		}
		return files.CloneLegacyReceipts(cfg.StateDir, stage, codec)
	}); err != nil {
		return err
	}
	fmt.Println("隔离加密克隆已生成；没有安装或修改 systemd 单元，证书指纹：", pin)
	return nil
}
