package proxyroute

import "aurora3/internal/winlocal"

func System() map[string]string { return winlocal.ProxyEnv() }
