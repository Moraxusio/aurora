package wire

import (
	"context"
	"sync"
)

type acceptReleaseKey struct{}

func WithAcceptRelease(ctx context.Context, f func()) context.Context {
	var once sync.Once
	return context.WithValue(ctx, acceptReleaseKey{}, func() { once.Do(f) })
}

func AcceptReleaseFrom(ctx context.Context) func() {
	if f, ok := ctx.Value(acceptReleaseKey{}).(func()); ok {
		return f
	}
	return func() {}
}

func ReleaseAccept(ctx context.Context) { AcceptReleaseFrom(ctx)() }
