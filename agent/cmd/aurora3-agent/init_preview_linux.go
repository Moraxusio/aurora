package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"aurora3/internal/entry"
)

func initProtectedPreview(args []string, input io.Reader) error {
	f := flag.NewFlagSet("init-protected-preview", flag.ContinueOnError)
	dest := f.String("dest", "", "尚不存在的隔离验收目录")
	instance := f.String("instance", "", "具名验收实例")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || !filepath.IsAbs(*dest) || *instance == "" || os.Getenv("INVOCATION_ID") != "" {
		return errors.New("仅支持手工指定独立绝对路径和具名验收实例")
	}
	// Token is supplied over a closed pipe, not as an argument or in a log.
	token, err := io.ReadAll(io.LimitReader(input, 67))
	defer clear(token)
	if err != nil || len(token) > 66 {
		return errors.New("无法从标准输入读取配对令牌")
	}
	if err := entry.InitializeLinuxPreview(*dest, *instance, string(bytes.TrimSpace(token))); err != nil {
		return err
	}
	fmt.Println("已建立隔离加密状态；未安装系统服务")
	return nil
}
