//go:build linux

// aurora3-sshpeer is a test SSH server for the client's install wizard
// (app/packages/aurora_install). It runs `exec` requests with sh -c as the
// user that started it, so tests need no sshd and no root. Password and
// public-key logins are checked against its flags. It prints
// {"addr","host_key_sha256"} and serves until stdin closes.
//
//	aurora3-sshpeer -user U -password P [-authorized-key "ssh-ed25519 AAAA..."]
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/crypto/ssh"
)

func main() {
	user := flag.String("user", "test", "user name to accept")
	password := flag.String("password", "", "password to accept (empty: none)")
	authKey := flag.String("authorized-key", "", "public key to accept, authorized_keys format")
	listen := flag.String("listen", "127.0.0.1:0", "address")
	flag.Parse()

	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		log.Fatal(err)
	}
	var allowed ssh.PublicKey
	if *authKey != "" {
		allowed, _, _, _, err = ssh.ParseAuthorizedKey([]byte(*authKey))
		if err != nil {
			log.Fatal(err)
		}
	}
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, p []byte) (*ssh.Permissions, error) {
			if *password != "" && c.User() == *user && subtle.ConstantTimeCompare(p, []byte(*password)) == 1 {
				return nil, nil
			}
			return nil, errors.New("denied")
		},
		PublicKeyCallback: func(c ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if allowed != nil && c.User() == *user && bytes.Equal(k.Marshal(), allowed.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("denied")
		},
	}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	b, _ := json.Marshal(map[string]string{"addr": ln.Addr().String(), "host_key_sha256": ssh.FingerprintSHA256(signer.PublicKey())})
	fmt.Println(string(b))
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go serve(c, cfg)
	}
}

func serve(c net.Conn, cfg *ssh.ServerConfig) {
	defer c.Close()
	_, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			_ = nc.Reject(ssh.UnknownChannelType, "only session")
			continue
		}
		ch, in, err := nc.Accept()
		if err != nil {
			continue
		}
		go session(ch, in)
	}
}

func session(ch ssh.Channel, in <-chan *ssh.Request) {
	defer ch.Close()
	for req := range in {
		switch req.Type {
		case "env":
			_ = req.Reply(true, nil)
		case "exec":
			var p struct{ Command string }
			if err := ssh.Unmarshal(req.Payload, &p); err != nil {
				_ = req.Reply(false, nil)
				return
			}
			_ = req.Reply(true, nil)
			code := run(ch, p.Command)
			_, _ = ch.SendRequest("exit-status", false, binary.BigEndian.AppendUint32(nil, uint32(code)))
			return
		default:
			_ = req.Reply(false, nil)
		}
	}
}

func run(ch ssh.Channel, command string) int {
	cmd := exec.Command("/bin/sh", "-c", command)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = ch, ch, ch.Stderr()
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Exited() {
				return ws.ExitStatus()
			}
			return 255
		}
		_, _ = fmt.Fprintln(ch.Stderr(), err)
		return 127
	}
	return 0
}
