#!/bin/bash
# End-to-end test of the client's install wizard (G5.6) on a test machine:
# the Dart installer (app/packages/aurora_install/test/e2e/e2e.dart) logs in to
# aurora3-sshpeer, uploads a signed aurora3-agent, installs it with the real
# four-stage installer, and dials it directly. Run as root: the SSH peer then
# runs commands as root, like a root login. With --sudo the peer runs as a
# normal user and the installer goes through sudo with a password.
#
#   install-e2e.sh DIR [--sudo]
#
# DIR holds: e2e (Dart, built for linux with its lib/), aurora3-sshpeer,
# release/ (signed build) and trust.pub. Only v3 names are written on the
# machine, and all are removed at the end; v2 is compared before and after.
set -u
SRC=${1:?usage: install-e2e.sh DIR [--sudo]}
MODE=${2:-root}
W=/tmp/aurora3-e2e
fails=0
check() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
v2state() {
  echo "unit: $(systemctl is-active aurora-agent 2>/dev/null) pid=$(systemctl show -p MainPID --value aurora-agent 2>/dev/null)"
  echo "listen7710: $(ss -ltnH 'sport = :7710' | wc -l)"
  for f in /usr/local/bin/aurora-agent /etc/systemd/system/aurora-agent.service /etc/aurora/agent.json; do
    [ -e "$f" ] && echo "$f $(stat -c '%s %Y %a' "$f")" || echo "$f missing"
  done
}
cleanup_v3() {
  systemctl stop aurora3-agent 2>/dev/null; systemctl disable aurora3-agent 2>/dev/null
  rm -f /etc/systemd/system/aurora3-agent.service /usr/local/bin/aurora3-agent /run/aurora3-install.lock
  rm -rf /etc/aurora3 /var/lib/aurora3
  systemctl daemon-reload; systemctl reset-failed aurora3-agent 2>/dev/null
}
field() { python3 -c '
import json, sys
want = sys.argv[1]
for l in sys.stdin.read().splitlines():
    if not l.startswith("{"): continue
    d = json.loads(l)
    if want in d:
        v = d[want]
print("" if "v" not in dir() else (str(v).lower() if isinstance(v, bool) else v))' "$1"; }

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
for p in /usr/local/bin/aurora3-agent /etc/systemd/system/aurora3-agent.service /etc/aurora3 /var/lib/aurora3; do
  [ -e "$p" ] && { echo "refusing: $p already exists"; exit 1; }
done
V2_BEFORE=$(v2state)
rm -rf "$W"; mkdir -p "$W"; cp -r "$SRC"/. "$W/"; chmod -R a+rX "$W"; chmod 755 "$W/aurora3-sshpeer" "$W/bin/e2e"

PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
PEER_USER=root
if [ "$MODE" = --sudo ]; then
  # A throwaway user with password sudo, removed at the end.
  PEER_USER=aurora3e2e
  id "$PEER_USER" >/dev/null 2>&1 && { echo "refusing: user $PEER_USER exists"; exit 1; }
  useradd -m -s /bin/sh "$PEER_USER"
  echo "$PEER_USER:$PASS" | chpasswd
  echo "$PEER_USER ALL=(root) ALL" > /etc/sudoers.d/aurora3e2e; chmod 440 /etc/sudoers.d/aurora3e2e
fi
coproc PEER { runuser -u "$PEER_USER" -- "$W/aurora3-sshpeer" -user "$PEER_USER" -password "$PASS"; }
read -r line <&"${PEER[0]}"
ADDR=$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["addr"])')
HK=$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["host_key_sha256"])')
echo "== ssh peer $ADDR as $PEER_USER, host key $HK"

SUDO_ARG=""; [ "$MODE" = --sudo ] && SUDO_ARG="$PASS"
out=$("$W/bin/e2e" "$ADDR" "$HK" "$PEER_USER" "$PASS" "$W/release" "$(cat "$W/trust.pub")" $SUDO_ARG 2>&1); code=$?
echo "$out" | sed 's/^/     /'
check "$code" 0 "e2e exit 0"
check "$(echo "$out" | field host_key_check)" hostKeyRejected "unknown host key stops the login"
check "$(echo "$out" | field wrong_password)" auth "wrong password refused"
check "$(echo "$out" | field result)" installed "installed"
check "$(echo "$out" | field dialed_version)" 3.0.1 "direct link to the new agent"
check "$(echo "$out" | field direct_info_same)" true "direct-info gives the same pin and token"
check "$(systemctl is-active aurora3-agent)" active "unit active"
check "$(ls -d /tmp/aurora3-upload-* 2>/dev/null | wc -l)" 0 "upload dir removed"
if [ "$MODE" = --sudo ]; then
  check "$(python3 -c 'import json; print([r["path"] for r in json.load(open("/etc/aurora3/agent.json"))["roots"] if r["id"]=="home"][0])')" "/home/$PEER_USER" "home root is the login user's"
fi

kill "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null
echo "== cleanup"
cleanup_v3
if [ "$MODE" = --sudo ]; then
  rm -f /etc/sudoers.d/aurora3e2e; userdel -r "$PEER_USER" 2>/dev/null
  check "$(id "$PEER_USER" >/dev/null 2>&1 && echo yes || echo no)" no "test user removed"
fi
rm -rf "$W" /tmp/aurora3-upload-*
check "$(ls -d /usr/local/bin/aurora3* /etc/aurora3 /var/lib/aurora3 /etc/systemd/system/aurora3* /etc/systemd/system/*/aurora3* 2>/dev/null | wc -l)" 0 "no v3 files"
check "$(ss -ltnH 'sport = :17710' | wc -l)" 0 "17710 closed"
V2_AFTER=$(v2state)
if [ "$V2_BEFORE" = "$V2_AFTER" ]; then echo "  ok   v2 unchanged"; else echo "  FAIL v2 changed"; diff <(echo "$V2_BEFORE") <(echo "$V2_AFTER"); fails=$((fails+1)); fi
echo "failures: $fails"
exit $fails
