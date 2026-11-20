//go:build !windows

package main

import "fmt"

func main() {
	fmt.Println("Aurora 单文件客户端启动器仅支持 Windows")
}
