package main

import (
	"fmt"
	"os"
)

// Version is set at build time with -ldflags "-X main.Version=...".
var Version = "3.0.0-dev"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(Version)
		return
	}
	fmt.Fprintln(os.Stderr, "aurora3-agent: no service is enabled yet")
	os.Exit(2)
}
