// Package devprocess owns development-tool process trees and their stdio pipes.
package devprocess

import (
	"errors"
	"os"
	"sync"
)

type child interface {
	Wait() error
	Kill(bool)
	Close()
}

type Process struct {
	Stdin, Stdout, Stderr *os.File
	child                 child
	done                  chan struct{}
	err                   error
	closeOnce             sync.Once
}

func Start(args []string, cwd string, env []string) (*Process, error) {
	if len(args) == 0 {
		return nil, errors.New("empty command")
	}
	p := &Process{}
	var all []*os.File
	pipe := func() (*os.File, *os.File, error) {
		r, w, err := os.Pipe()
		if err == nil {
			all = append(all, r, w)
		}
		return r, w, err
	}
	ok := false
	defer func() {
		if !ok {
			for _, f := range all {
				f.Close()
			}
		}
	}()
	in, write, err := pipe()
	if err != nil {
		return nil, err
	}
	out, childOut, err := pipe()
	if err != nil {
		return nil, err
	}
	stderr, childErr, err := pipe()
	if err != nil {
		return nil, err
	}
	p.child, err = start(args, cwd, env, in, childOut, childErr)
	if err != nil {
		return nil, err
	}
	in.Close()
	childOut.Close()
	childErr.Close()
	p.Stdin, p.Stdout, p.Stderr = write, out, stderr
	p.done = make(chan struct{})
	go func() { p.err = p.child.Wait(); close(p.done) }()
	ok = true
	return p, nil
}

func (p *Process) Kill()       { p.child.Kill(true) }
func (p *Process) Wait() error { <-p.done; return p.err }
func (p *Process) Close() {
	p.closeOnce.Do(func() {
		p.Kill()
		p.Stdin.Close()
		p.Stdout.Close()
		p.Stderr.Close()
		<-p.done
		p.child.Close()
	})
}

func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var exit interface{ ExitCode() int }
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	return -1
}
