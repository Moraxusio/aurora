#!/bin/bash
# The SSH side of app/integration_test/install_ui_test.dart, run as root on a
# test machine: aurora3-sshpeer on 127.0.0.1:17722 (root login, a random
# password), so the UI's wizard installs the real aurora3-agent. Prints the
# peer's address, host key and password as one JSON line, then waits until
# stdin closes. On exit every v3 name is removed and v2 is compared.
#   ui-ssh.sh SSHPEER
set -u
PEER=${1:?usage: ui-ssh.sh SSHPEER}
W=/tmp/aurora3-ui-ssh
[ "$(id -u)" = 0 ] || { echo '{"error":"must run as root"}'; exit 1; }
for p in /usr/local/bin/aurora3-agent /etc/systemd/system/aurora3-agent.service /etc/aurora3 /var/lib/aurora3; do
  [ -e "$p" ] && { echo "{\"error\":\"$p exists\"}"; exit 1; }
done
v2state() {
  echo "unit: $(systemctl is-active aurora-agent) pid=$(systemctl show -p MainPID --value aurora-agent)"
  echo "listen7710: $(ss -ltnH 'sport = :7710' | wc -l)"
  for f in /usr/local/bin/aurora-agent /etc/systemd/system/aurora-agent.service; do [ -e "$f" ] && echo "$f $(stat -c '%s %Y' "$f")"; done
}
V2_BEFORE=$(v2state)
rm -rf "$W"; mkdir -p "$W"; cp "$PEER" "$W/aurora3-sshpeer"; chmod 755 "$W/aurora3-sshpeer"
PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
coproc P { "$W/aurora3-sshpeer" -user root -password "$PASS" -listen 127.0.0.1:17722; }
read -r line <&"${P[0]}"
HK=$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["host_key_sha256"])')
echo "{\"addr\":\"127.0.0.1:17722\",\"host_key\":\"$HK\",\"password\":\"$PASS\"}"
cat >/dev/null
kill "$P_PID" 2>/dev/null; wait "$P_PID" 2>/dev/null
# what the UI installed
systemctl stop aurora3-agent 2>/dev/null; systemctl disable aurora3-agent 2>/dev/null
for u in $(systemctl list-units --all --plain --no-legend 'aurora3-tmux-*' | awk '{print $1}'); do systemctl stop "$u"; done
rm -f /etc/systemd/system/aurora3-agent.service /usr/local/bin/aurora3-agent /run/aurora3-install.lock
rm -rf /etc/aurora3 /var/lib/aurora3 "$W" /tmp/aurora3-upload-*
systemctl daemon-reload; systemctl reset-failed 'aurora3-*' 2>/dev/null
left=$(ls -d /usr/local/bin/aurora3* /etc/aurora3 /var/lib/aurora3 /etc/systemd/system/aurora3* 2>/dev/null | wc -l)
V2_AFTER=$(v2state)
[ "$V2_BEFORE" = "$V2_AFTER" ] && v2=unchanged || v2=CHANGED
echo "cleanup: v3 left $left, v2 $v2" >&2
