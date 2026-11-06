#!/bin/bash
# Terminal end to end (G2.1): a real aurora3-agent run by a normal user under
# /tmp on port 17790 (no install, no systemd unit: tmux starts directly), and
# the Dart client's terminal_e2e against it.
#   terminal-e2e.sh DIR    (DIR: aurora3-agent, bin/terminal_e2e + lib/)
set -u
SRC=${1:?usage: terminal-e2e.sh DIR}
W=/tmp/aurora3-term-e2e
rm -rf "$W"; mkdir -p "$W/state" "$W/home"
cp -r "$SRC"/. "$W/"; chmod 755 "$W/aurora3-agent" "$W/bin/terminal_e2e"
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$W/agent.json" <<EOF
{"listen":"127.0.0.1:17790","token":"$TOKEN","state_dir":"$W/state",
 "roots":[{"id":"home","path":"$W/home"}],"audit_log":"$W/state/audit.log"}
EOF
chmod 600 "$W/agent.json"
"$W/aurora3-agent" run --config "$W/agent.json" 2>"$W/agent.log" &
AGENT=$!
for i in $(seq 50); do [ -f "$W/state/agent.crt" ] && ss -ltnH 'sport = :17790' | grep -q . && break; sleep 0.1; done
PIN=$(openssl x509 -in "$W/state/agent.crt" -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)
"$W/bin/terminal_e2e" 127.0.0.1:17790 "$PIN" "$TOKEN"
code=$?
kill $AGENT; wait $AGENT 2>/dev/null
# The tmux server this agent started (socket aurora3, owned by this user).
"$W/state/bin/tmux" -L aurora3 kill-server 2>/dev/null || ls "$W/state/bin/"tmux-* >/dev/null 2>&1 && for b in "$W/state/bin/"tmux-*; do "$b" -L aurora3 kill-server 2>/dev/null; done
echo "audit: $(cut -c1-200 "$W/state/audit.log" | tr '\n' ' ')"
[ $code -ne 0 ] && tail -20 "$W/agent.log"
rm -rf "$W"
echo "tmux left for $(id -un): $(pgrep -u "$(id -u)" -f -- '-L aurora3( |$)' | wc -l)"
exit $code
