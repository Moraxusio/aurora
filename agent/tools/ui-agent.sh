#!/bin/bash
# Starts a real aurora3-agent for UI work, as the normal user under /tmp on
# 127.0.0.1:17791 (no install, no systemd, no root). Prints the endpoint as
# JSON and keeps running until stdin closes. All files are removed on exit.
#   ui-agent.sh AGENT_BINARY
set -u
BIN=${1:?usage: ui-agent.sh AGENT_BINARY}
W=/tmp/aurora3-ui-agent
rm -rf "$W"; mkdir -p "$W/state" "$W/home/docs"
cp "$BIN" "$W/aurora3-agent"; chmod 755 "$W/aurora3-agent"
echo "hello from the ui agent" > "$W/home/docs/readme.txt"
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$W/agent.json" <<EOF
{"name":"wsl-ui","listen":"127.0.0.1:17791","token":"$TOKEN","state_dir":"$W/state",
 "roots":[{"id":"home","label":"测试目录","path":"$W/home"}],"audit_log":"$W/state/audit.log"}
EOF
chmod 600 "$W/agent.json"
"$W/aurora3-agent" run --config "$W/agent.json" 2>"$W/agent.log" &
AGENT=$!
cleanup() {
  kill $AGENT 2>/dev/null; wait $AGENT 2>/dev/null
  for b in "$W/state/bin/"tmux-*; do [ -x "$b" ] && "$b" -L aurora3 kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
for i in $(seq 50); do [ -f "$W/state/agent.crt" ] && ss -ltnH 'sport = :17791' | grep -q . && break; sleep 0.1; done
PIN=$(openssl x509 -in "$W/state/agent.crt" -outform der | sha256sum | cut -d' ' -f1)
echo "{\"addr\":\"127.0.0.1:17791\",\"pin\":\"$PIN\",\"token\":\"$TOKEN\"}"
cat >/dev/null
