// aurora3-testnode is a Trojan server for client tests: it stands in for the
// airport's node, so a test can check that the traffic of a session really
// left through the node the user chose. It is not shipped.
//
// It listens on 127.0.0.1 with a certificate made when it starts (nothing is
// kept), accepts one password, and answers every tunnel by echoing what it
// receives. It prints one JSON line {"port":N} when it is ready, and then one
// line per tunnel it opened: "target host:port". With -log FILE the same lines
// are appended to FILE as well, for a test that cannot read this process's
// output while it runs. It runs until stdin closes.
package main

import (
	"bufio"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"

	"aurora3/internal/wire"
)

func main() {
	secret := flag.String("secret", "", "the password the node accepts")
	port := flag.Int("port", 0, "port to listen on (0: any free one)")
	logPath := flag.String("log", "", "also append one line per tunnel to this file")
	flag.Parse()
	if *secret == "" {
		fmt.Fprintln(os.Stderr, "aurora3-testnode: -secret is required")
		os.Exit(2)
	}
	if err := run(*secret, *port, *logPath); err != nil {
		fmt.Fprintln(os.Stderr, "aurora3-testnode:", err)
		os.Exit(1)
	}
}

func run(secret string, port int, logPath string) error {
	dir, err := os.MkdirTemp("", "aurora3-testnode-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	cert, _, err := wire.LoadOrCreateCert(dir, "node")
	if err != nil {
		return err
	}
	ln, err := tls.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port), &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		return err
	}
	defer ln.Close()
	sum := sha256.Sum224([]byte(secret))
	want := hex.EncodeToString(sum[:])

	var mu sync.Mutex
	var logf *os.File
	if logPath != "" {
		if logf, err = os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err != nil {
			return err
		}
		defer logf.Close()
	}
	say := func(s string) {
		mu.Lock()
		defer mu.Unlock()
		fmt.Println(s)
		if logf != nil {
			fmt.Fprintln(logf, s)
		}
	}
	b, _ := json.Marshal(map[string]int{"port": ln.Addr().(*net.TCPAddr).Port})
	say(string(b))

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go serve(c, want, say)
		}
	}()
	_, _ = io.Copy(io.Discard, bufio.NewReader(os.Stdin))
	return nil
}

// serve reads the Trojan request: hashed password, CRLF, command, destination, CRLF.
func serve(c net.Conn, want string, say func(string)) {
	defer c.Close()
	br := bufio.NewReader(c)
	pw := make([]byte, 58)
	if _, err := io.ReadFull(br, pw); err != nil || strings.TrimSuffix(string(pw), "\r\n") != want {
		return
	}
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil || head[0] != 1 {
		return
	}
	var host string
	switch head[1] {
	case 1:
		b := make([]byte, 4)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 4:
		b := make([]byte, 16)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 3:
		l, err := br.ReadByte()
		if err != nil {
			return
		}
		b := make([]byte, l)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = string(b)
	default:
		return
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(br, pb); err != nil {
		return
	}
	if _, err := io.ReadFull(br, make([]byte, 2)); err != nil {
		return
	}
	say(fmt.Sprintf("target %s:%d", host, int(pb[0])<<8|int(pb[1])))
	_, _ = io.Copy(c, br)
}
