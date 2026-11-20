package main

import (
	"errors"
	"flag"
	"fmt"

	"aurora3/internal/ai"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	"aurora3/internal/statecrypt"
)

func cloneProtectedPreview(args []string) error {
	f := flag.NewFlagSet("clone-protected-preview", flag.ContinueOnError)
	source := f.String("source", "", "已停止的 3.x 本机 agent 状态目录")
	dest := f.String("dest", "", "尚不存在的隔离验收目录")
	stopped := f.Bool("source-stopped", false, "确认旧版客户端和 agent 均已退出")
	if err := f.Parse(args); err != nil {
		return err
	}
	if !*stopped || f.NArg() != 0 || *source == "" || *dest == "" {
		return errors.New("必须显式指定 --source、--dest 并确认 --source-stopped")
	}
	pin, err := cloneLocalState(*source, *dest, *dest)
	if err != nil {
		return err
	}
	fmt.Println("隔离加密克隆已生成；原状态未改动，证书指纹：", pin)
	return nil
}

func cloneLocalState(source, dest, final string) (string, error) {
	roots, err := localRoots()
	if err != nil {
		return "", err
	}
	workspaces := ai.CloneWorkspaces{Final: final}
	for _, root := range roots {
		workspaces.Legacy = append(workspaces.Legacy, ai.Root{ID: root.ID, Path: root.Path})
	}
	var pin string
	if err := statecrypt.CloneDirectory(source, dest, func(stage string, names []string) error {
		if err := entry.CheckLegacyCloneNames(source, names, true); err != nil {
			return err
		}
		codec, fingerprint, err := entry.CloneLocalIdentity(source, stage)
		if err != nil {
			return err
		}
		pin = fingerprint
		if err := ai.CloneLegacyStore(source, stage, codec, workspaces); err != nil {
			return err
		}
		return files.CloneLegacyReceipts(source, stage, codec)
	}); err != nil {
		return "", err
	}
	return pin, nil
}
