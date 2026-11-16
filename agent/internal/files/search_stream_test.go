//go:build linux || windows

package files

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"
)

type cancelSearchRunner struct{ entered, cancelled chan struct{} }

func (r *cancelSearchRunner) Runner(string) (Runner, error) { return r, nil }
func (r *cancelSearchRunner) LsFiles(ctx context.Context, _ int) ([]string, bool, error) {
	close(r.entered)
	<-ctx.Done()
	close(r.cancelled)
	return nil, false, ctx.Err()
}

func TestSearchStreamResetCancelsBackendWork(t *testing.T) {
	r := &cancelSearchRunner{entered: make(chan struct{}), cancelled: make(chan struct{})}
	e := &Env{Roots: []Root{{ID: "work", Path: t.TempDir()}}, Repos: r}
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		done <- e.fsSearchStream(context.Background(), server,
			json.RawMessage(`{"root":"work","path":"/","query":"needle"}`))
	}()
	select {
	case <-r.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("search did not start")
	}
	client.Close()
	select {
	case <-r.cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("backend was not cancelled")
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("search workers did not terminate")
	}
}
