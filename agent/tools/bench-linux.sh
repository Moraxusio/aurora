#!/bin/bash
# Go and Dart clients against aurora3-testpeer, all on Linux loopback.
# Uses only the directory below. Stage it first (from Windows):
#   GOOS=linux go build -o <dir>/aurora3-testpeer ./cmd/aurora3-testpeer
#   GOOS=linux go build -o <dir>/aurora3-bench ./cmd/aurora3-bench
#   dart compile exe --target-os linux --target-arch x64 bin/bench.dart -o <dir>/bench-dart-linux
set -u
D=${1:-/tmp/aurora3-bench}
run() {
  local side=$1
  coproc PEER { exec "$D/aurora3-testpeer" -listen 127.0.0.1:0; }
  read -r line <&"${PEER[0]}"
  addr=$(echo "$line" | sed 's/.*"addr":"\([^"]*\)".*/\1/')
  pin=$(echo "$line" | sed 's/.*"pin":"\([^"]*\)".*/\1/')
  token=$(echo "$line" | sed 's/.*"token":"\([^"]*\)".*/\1/')
  echo "=== $side (linux loopback)"
  if [ "$side" = go ]; then
    "$D/aurora3-bench" -addr "$addr" -pin "$pin" -token "$token"
  else
    "$D/bench-dart-linux" "$addr" "$pin" "$token"
  fi
  exec {PEER[1]}>&-
  wait "$PEER_PID" 2>/dev/null
}
run go
run dart
