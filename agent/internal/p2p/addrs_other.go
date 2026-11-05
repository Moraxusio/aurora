//go:build !linux && !windows

package p2p

func localAddrs() []Local { return fallbackAddrs() }
