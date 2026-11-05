// aurora3-tlspeer is a test server for the client's TLS engine
// (app/packages/aurora_tls): Go's crypto/tls with the agent's certificate
// type and settings (wire.LoadOrCreateCert, wire.ServerTLS). It prints
// {"addr","pin"} and serves until killed.
//
//	-mode echo         send back everything received
//	-mode source       send the byte pattern i%251 without end
//	-mode hello-close  send "hello", then close_notify
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"

	"aurora3/internal/wire"
)

func main() {
	mode := flag.String("mode", "echo", "echo | source | hello-close")
	flag.Parse()
	// The certificate is made in a temporary directory that is removed at
	// once: tests kill this process, so a deferred removal would never run.
	dir, err := os.MkdirTemp("", "aurora3-tlspeer-")
	if err != nil {
		panic(err)
	}
	cert, pin, err := wire.LoadOrCreateCert(dir, "peer")
	os.RemoveAll(dir)
	if err != nil {
		panic(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", wire.ServerTLS(cert))
	if err != nil {
		panic(err)
	}
	b, _ := json.Marshal(map[string]string{"addr": ln.Addr().String(), "pin": pin})
	fmt.Println(string(b))
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go serve(c, *mode)
	}
}

func serve(c net.Conn, mode string) {
	defer c.Close()
	switch mode {
	case "echo":
		_, _ = io.Copy(c, c)
	case "source":
		buf := make([]byte, 256<<10)
		var off int64
		for {
			for i := range buf {
				buf[i] = byte((off + int64(i)) % 251)
			}
			if _, err := c.Write(buf); err != nil {
				return
			}
			off += int64(len(buf))
		}
	case "hello-close":
		_, _ = c.Write([]byte("hello"))
		if tc, ok := c.(*tls.Conn); ok {
			_ = tc.CloseWrite()
		}
		_, _ = io.Copy(io.Discard, c)
	}
}
