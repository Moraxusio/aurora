#!/bin/bash
# Starts a real aurora3-agent for UI work, as the normal user under /tmp on
# 127.0.0.1:17791 (no install, no systemd, no root). Prints the endpoint as
# JSON and keeps running until stdin closes. All files are removed on exit.
#   ui-agent.sh AGENT_BINARY [PORT] [WORK_DIR] [CREATE_LEGACY_SESSION]
set -u
BIN=${1:?usage: ui-agent.sh AGENT_BINARY}
PORT=${2:-17791}
W=${3:-/tmp/aurora3-ui-agent}
LEGACY=${4:-0}
BANNER_PORT=$((PORT + 1))
rm -rf "$W"; mkdir -p "$W/state" "$W/home/docs"
cp "$BIN" "$W/aurora3-agent"; chmod 755 "$W/aurora3-agent"
echo "hello from the ui agent" > "$W/home/docs/readme.txt"
# a repository with one modified file, one untracked file and two commits
mkdir -p "$W/home/proj"
(
  cd "$W/home/proj" || exit 0
  git init -q -b main 2>/dev/null || exit 0
  git config user.name T; git config user.email t@example.com
  printf 'one\ntwo\nthree\n' > a.txt
  git add a.txt; git commit -q -m "first commit"
  printf 'one\ntwo\nthree\nfour\n' > a.txt
  git commit -qam "second commit"
  printf 'one\nTWO\nthree\nfour\n' > a.txt
  printf 'brand new\n' > new.txt
)
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$W/agent.json" <<EOF
{"name":"wsl-ui","listen":"127.0.0.1:$PORT","token":"$TOKEN","state_dir":"$W/state",
 "roots":[{"id":"home","label":"测试目录","path":"$W/home"}],"audit_log":"$W/state/audit.log"}
EOF
chmod 600 "$W/agent.json"
# a server-side TCP service for the port forward test: answers one line, per connection
( while true; do printf 'ui-port-banner\n' | nc -N -l 127.0.0.1 "$BANNER_PORT" 2>/dev/null || sleep 0.2; done ) &
NCLOOP=$!
"$W/aurora3-agent" run --config "$W/agent.json" 2>"$W/agent.log" &
AGENT=$!
cleanup() {
  pkill -P "$NCLOOP" 2>/dev/null; kill "$NCLOOP" 2>/dev/null
  kill $AGENT 2>/dev/null; wait $AGENT 2>/dev/null
  for b in "$W/state/bin/"tmux-*; do [ -x "$b" ] && "$b" -L aurora3 kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
for i in $(seq 50); do [ -f "$W/state/agent.crt" ] && ss -ltnH "sport = :$PORT" | grep -q . && break; sleep 0.1; done
PIN=$(openssl x509 -in "$W/state/agent.crt" -outform der | sha256sum | cut -d' ' -f1)
echo "{\"addr\":\"127.0.0.1:$PORT\",\"pin\":\"$PIN\",\"token\":\"$TOKEN\"}"
if [ "$LEGACY" = 1 ]; then
  # Do not delay the endpoint line: the Windows harness reads it before the
  # first client session causes the bundled tmux to be unpacked.
  (
    for i in $(seq 300); do
      TMUX=$(find "$W/state/bin" -maxdepth 1 -type f -name 'tmux-*' -perm -111 2>/dev/null | head -1)
      if [ -x "$TMUX" ] && "$TMUX" -L aurora3 list-sessions >/dev/null 2>&1; then
        "$TMUX" -L aurora3 has-session -t =legacy >/dev/null 2>&1 || "$TMUX" -L aurora3 new-session -d -s legacy
        "$TMUX" -L aurora3 set-option -u -t =legacy: @aurora3_proxy
        break
      fi
      sleep 0.1
    done
  ) &
fi
cat >/dev/null
