#!/bin/bash
# Real install test of aurora3-agent (G3.1), run as root on a test machine
# with systemd. It writes only v3 names (D-71) and removes all of them at the
# end; v2's unit, binary, config and port are compared before and after.
#
#   install-real.sh DIR
#
# DIR holds linux binaries built by agent/tools/install-real.ps1:
#   aurora3-agent-3.0.1, -3.0.2, -3.0.4   real agents with those versions
#   aurora3-agent-3.0.3                   aurora3-brokenagent (service exits)
#   aurora3-probe
# It refuses to start when any v3 name already exists.
set -u
SRC=${1:?usage: install-real.sh DIR}
W=/tmp/aurora3-real
USER_NAME=${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}
fails=0
check() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
# field PATH: a dotted field of the last JSON line on stdin.
field() { python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.startswith("{")]
v = json.loads(lines[-1]) if lines else {}
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
state3() { for f in /usr/local/bin/aurora3-agent /etc/systemd/system/aurora3-agent.service /etc/aurora3/agent.json; do [ -e "$f" ] && sha "$f" || echo none; done | tr '\n' ' '; }
v2state() {
  echo "unit: $(systemctl is-active aurora-agent 2>/dev/null) $(systemctl is-enabled aurora-agent 2>/dev/null) pid=$(systemctl show -p MainPID --value aurora-agent 2>/dev/null)"
  echo "listen7700/7710: $(ss -ltnH 'sport = :7700' | wc -l)/$(ss -ltnH 'sport = :7710' | wc -l)"
  for f in /usr/local/bin/aurora-agent /etc/systemd/system/aurora-agent.service /etc/aurora/agent.json; do
    [ -e "$f" ] && echo "$f $(stat -c '%s %Y %a' "$f")" || echo "$f missing"
  done
  echo "tmux units: $(systemctl list-units --all --plain --no-legend 'aurora-tmux-*' 2>/dev/null | wc -l)"
}

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
for p in /usr/local/bin/aurora3-agent /etc/systemd/system/aurora3-agent.service /etc/aurora3 /var/lib/aurora3; do
  [ -e "$p" ] && { echo "refusing: $p already exists"; exit 1; }
done
V2_BEFORE=$(v2state)

rm -rf "$W"; mkdir -p "$W"
for v in 3.0.1 3.0.2 3.0.3 3.0.4; do cp "$SRC/aurora3-agent-$v" "$W/"; done
cp "$SRC/aurora3-probe" "$W/"
chmod 755 "$W"/*
inst() { local v=$1; shift; "$W/aurora3-agent-$v" install --sha256 "$(sha "$W/aurora3-agent-$v")" --name install-test "$@"; }
probe() { "$W/aurora3-probe" -addr 127.0.0.1:17710 -pin "$PIN" -token "$TOK" -op agent.info 2>&1; }

echo "== probe as a normal user ($USER_NAME): no root needed, nothing written"
out=$(runuser -u "$USER_NAME" -- "$W/aurora3-agent-3.0.1" install --probe 2>&1); code=$?
check "$code" 0 "exit 0"
check "$(echo "$out" | field probe.action)" install "action install"
check "$(echo "$out" | field probe.port_free)" true "17710 free"
echo "     v2 present: $(echo "$out" | field probe.v2)"
check "$(state3)" "none none none " "nothing written"

echo "== wrong sha256: refused, nothing written"
out=$("$W/aurora3-agent-3.0.1" install --sha256 "$(printf '0%.0s' $(seq 64))" 2>&1); code=$?
check "$code" 1 "exit 1"
check "$(echo "$out" | field result)" refused "refused"
check "$(state3)" "none none none " "nothing written"
check "$([ -e /var/lib/aurora3 ] && echo yes || echo no)" no "no state dir"
check "$([ -e /etc/aurora3 ] && echo yes || echo no)" no "no config dir"

echo "== install 3.0.1"
out=$(inst 3.0.1 2>&1); code=$?
echo "$out" | sed 's/"token":"[0-9a-f]*"/"token":"…"/; s/^/     /'
check "$code" 0 "exit 0"
check "$(echo "$out" | field result)" installed "installed"
check "$(systemctl is-active aurora3-agent)" active "unit active"
check "$(systemctl is-enabled aurora3-agent)" enabled "unit enabled"
check "$(stat -c %a /etc/aurora3/agent.json)" 600 "agent.json 0600"
check "$(stat -c %a /etc/aurora3)" 700 "/etc/aurora3 0700"
check "$(stat -c %a /var/lib/aurora3)" 700 "/var/lib/aurora3 0700"
check "$(ls -d /var/lib/aurora3/install-* /var/lib/aurora3/rollback-* 2>/dev/null | wc -l)" 0 "no stage or rollback dir left"
PIN=$(echo "$out" | field direct.cert_sha256); TOK=$(echo "$out" | field direct.token)
check "$(probe | field version)" 3.0.1 "direct link answers agent.info"

echo "== direct-info"
out=$(/usr/local/bin/aurora3-agent direct-info 2>&1); code=$?
check "$code" 0 "exit 0"
check "$(echo "$out" | field direct.token)" "$TOK" "same token"
check "$(echo "$out" | field direct.cert_sha256)" "$PIN" "same pin"
check "$(echo "$out" | field running)" true "running"
runuser -u "$USER_NAME" -- /usr/local/bin/aurora3-agent direct-info >/dev/null 2>&1
check "$?" 1 "normal user refused"

echo "== the same version again: nothing changes"
before=$(state3); pid=$(systemctl show -p MainPID --value aurora3-agent)
out=$(inst 3.0.1 2>&1); code=$?
check "$code" 0 "exit 0"
check "$(echo "$out" | field result)" up_to_date "up_to_date"
check "$(state3)" "$before" "files unchanged"
check "$(systemctl show -p MainPID --value aurora3-agent)" "$pid" "service not restarted"

echo "== upgrade to 3.0.2"
cfg=$(sha /etc/aurora3/agent.json)
out=$(inst 3.0.2 2>&1); code=$?
check "$code" 0 "exit 0"
check "$(echo "$out" | field result)" upgraded "upgraded"
check "$(echo "$out" | field previous)" 3.0.1 "previous 3.0.1"
check "$(sha /etc/aurora3/agent.json)" "$cfg" "agent.json kept"
check "$(echo "$out" | field direct.cert_sha256)" "$PIN" "certificate kept"
check "$(echo "$out" | field direct.token)" "$TOK" "token kept"
check "$(probe | field version)" 3.0.2 "3.0.2 answers"

echo "== broken 3.0.3: rolled back to 3.0.2"
before=$(state3); t0=$(date +%s)
out=$(inst 3.0.3 2>&1); code=$?
echo "$out" | grep -E '"stage":"(confirm|rollback)"' | sed 's/^/     /'
check "$code" 2 "exit 2"
check "$(echo "$out" | field result)" rolled_back "rolled_back"
check "$(state3)" "$before" "files byte-identical to before"
check "$(systemctl is-active aurora3-agent)" active "unit active again"
check "$(probe | field version)" 3.0.2 "3.0.2 answers again"
check "$(ls -d /var/lib/aurora3/install-* /var/lib/aurora3/rollback-* 2>/dev/null | wc -l)" 0 "rollback dir removed"
echo "     (took $(( $(date +%s) - t0 )) s)"

echo "== the SSH session drops mid-run (stdout closed after one byte): 3.0.4 still completes"
inst 3.0.4 | head -c 1 >/dev/null
for i in $(seq 60); do [ "$(probe | field version)" = 3.0.4 ] && break; sleep 0.5; done
check "$(probe | field version)" 3.0.4 "3.0.4 answers"
check "$(ls -d /var/lib/aurora3/install-* /var/lib/aurora3/rollback-* /usr/local/bin/aurora3-agent.aurora3-tmp-* 2>/dev/null | wc -l)" 0 "nothing left over"

echo "== cleanup: every v3 name"
systemctl stop aurora3-agent; systemctl disable aurora3-agent 2>/dev/null
rm -f /etc/systemd/system/aurora3-agent.service /usr/local/bin/aurora3-agent /run/aurora3-install.lock
rm -rf /etc/aurora3 /var/lib/aurora3 "$W"
systemctl daemon-reload; systemctl reset-failed aurora3-agent 2>/dev/null
check "$(ls -d /usr/local/bin/aurora3* /etc/aurora3 /var/lib/aurora3 /etc/systemd/system/aurora3* /etc/systemd/system/*/aurora3* 2>/dev/null | wc -l)" 0 "no v3 files"
check "$(systemctl list-units --all --plain --no-legend 'aurora3*' | wc -l)" 0 "no v3 units"
check "$(ss -ltnH 'sport = :17710' | wc -l)" 0 "17710 closed"

echo "== v2 before and after"
V2_AFTER=$(v2state)
if [ "$V2_BEFORE" = "$V2_AFTER" ]; then echo "  ok   v2 unchanged"; else echo "  FAIL v2 changed"; diff <(echo "$V2_BEFORE") <(echo "$V2_AFTER"); fails=$((fails+1)); fi
echo "$V2_AFTER" | sed 's/^/     /'
echo "failures: $fails"
exit $fails
