package devprocess

import (
	"aurora3/internal/winlocal"
	"os"
)

func start(args []string, cwd string, env []string, in, out, stderr *os.File) (child, error) {
	return winlocal.StartStdioCommand(args, cwd, env, in, out, stderr)
}
