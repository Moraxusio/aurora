#!/bin/bash
# Real install check of D-18/D-35 on a test machine (root): install
# aurora3-agent, create a session through the direct link, restart and
# upgrade the agent, and check the session (and a process in it) survive.
# Only v3 names are written; all are removed at the end. v2 is compared.
#   terminal-survives.sh DIR   (DIR: aurora3-agent-3.0.1, -3.0.2, aurora3-probe)
set -u
SRC=${1:?usage: terminal-survives.sh DIR}
W=/tmp/aurora3-survive
fails=0
check() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
field() { python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.startswith("{")]
v = json.loads(lines[-1]) if lines else {}
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
v2state() {
  echo "unit: $(systemctl is-active aurora-agent) pid=$(systemctl show -p MainPID --value aurora-agent)"
  echo "listen7710: $(ss -ltnH 'sport = :7710' | wc -l)"
  echo "v2 tmux units: $(systemctl list-units --all --plain --no-legend 'aurora-tmux-*' | wc -l)"
  for f in /usr/local/bin/aurora-agent /etc/systemd/system/aurora-agent.service; do [ -e "$f" ] && echo "$f $(stat -c '%s %Y' "$f")"; done
}
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
for p in /usr/local/bin/aurora3-agent /etc/systemd/system/aurora3-agent.service /etc/aurora3 /var/lib/aurora3; do
  [ -e "$p" ] && { echo "refusing: $p exists"; exit 1; }
done
[ "$(systemctl list-units --all --plain --no-legend 'aurora3-tmux-*' | wc -l)" = 0 ] || { echo "refusing: aurora3-tmux units exist"; exit 1; }
V2_BEFORE=$(v2state)
rm -rf "$W"; mkdir -p "$W"; cp "$SRC"/* "$W/"; chmod 755 "$W"/*
inst() { "$W/aurora3-agent-$1" install --sha256 "$(sha "$W/aurora3-agent-$1")" --name survive; }
op() { "$W/aurora3-probe" -addr 127.0.0.1:17710 -pin "$PIN" -token "$TOK" -op "$1" ${2:+-args "$2"} 2>&1; }

echo "== install 3.0.1 and open a session with a running process"
out=$(inst 3.0.1); check "$(echo "$out" | field result)" installed "installed"
PIN=$(echo "$out" | field direct.cert_sha256); TOK=$(echo "$out" | field direct.token)
check "$(op session.create '{"name":"keep"}' | field result.name)" keep "session created over the direct link"
check "$(systemctl list-units --plain --no-legend 'aurora3-tmux-*' | wc -l)" 1 "tmux runs in its own aurora3-tmux-* unit"
UNIT=$(systemctl list-units --plain --no-legend 'aurora3-tmux-*' | awk '{print $1}')
check "$(systemctl show -p ControlGroup --value aurora3-agent | grep -c tmux)" 0 "tmux is not in the agent's cgroup"
TMUX=$(ls /var/lib/aurora3/bin/tmux-* | head -1)
"$TMUX" -u -L aurora3 send-keys -t =keep: "sleep 9999 & echo \$! > /tmp/aurora3-survive/job.pid" Enter
sleep 1; JOB=$(cat "$W/job.pid" 2>/dev/null)
check "$([ -n "$JOB" ] && [ -d /proc/$JOB ] && echo yes)" yes "a job runs in the session"

echo "== restart the agent"
systemctl restart aurora3-agent; sleep 1
check "$(systemctl is-active "$UNIT")" active "tmux unit still active"
check "$([ -d /proc/$JOB ] && echo yes)" yes "the job survived the restart"
for i in $(seq 40); do op session.list >/dev/null 2>&1 && break; sleep 0.25; done
check "$(op session.list | python3 -c 'import json,sys; print(",".join(s["name"] for s in json.load(sys.stdin)["result"]["sessions"]))')" keep "session listed after the restart"

echo "== upgrade to 3.0.2"
out=$(inst 3.0.2); check "$(echo "$out" | field result)" upgraded "upgraded"
check "$([ -d /proc/$JOB ] && echo yes)" yes "the job survived the upgrade"
check "$(op session.list | python3 -c 'import json,sys; print(",".join(s["name"] for s in json.load(sys.stdin)["result"]["sessions"]))')" keep "session listed after the upgrade"

echo "== session.kill ends the session and its unit"
op session.kill '{"name":"keep"}' >/dev/null
sleep 1
check "$([ -d /proc/$JOB ] && echo yes || echo no)" no "job ended with the session"
for i in $(seq 20); do [ "$(systemctl list-units --plain --no-legend 'aurora3-tmux-*' | wc -l)" = 0 ] && break; sleep 0.25; done
check "$(systemctl list-units --all --plain --no-legend 'aurora3-tmux-*' | wc -l)" 0 "tmux unit gone"

echo "== cleanup"
systemctl stop aurora3-agent; systemctl disable aurora3-agent 2>/dev/null
for u in $(systemctl list-units --all --plain --no-legend 'aurora3-tmux-*' | awk '{print $1}'); do systemctl stop "$u"; done
rm -f /etc/systemd/system/aurora3-agent.service /usr/local/bin/aurora3-agent /run/aurora3-install.lock
rm -rf /etc/aurora3 /var/lib/aurora3 "$W"
systemctl daemon-reload; systemctl reset-failed 'aurora3-*' 2>/dev/null
check "$(ls -d /usr/local/bin/aurora3* /etc/aurora3 /var/lib/aurora3 /etc/systemd/system/aurora3* 2>/dev/null | wc -l)" 0 "no v3 files"
check "$(systemctl list-units --all --plain --no-legend 'aurora3*' | wc -l)" 0 "no v3 units"
V2_AFTER=$(v2state)
if [ "$V2_BEFORE" = "$V2_AFTER" ]; then echo "  ok   v2 unchanged"; else echo "  FAIL v2 changed"; diff <(echo "$V2_BEFORE") <(echo "$V2_AFTER"); fails=$((fails+1)); fi
echo "failures: $fails"
exit $fails
