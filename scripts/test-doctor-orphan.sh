#!/usr/bin/env bash
#
# End-to-end check that `pm3 doctor --fix` really cleans up an orphan.
#
# A daemon binds an arbitrary port and publishes it in `daemon.port`, so a
# second daemon for one home is unreachable: it keeps the processes it started,
# but `pm3 list` cannot show them and `pm3 kill` cannot stop them. `doctor`
# reports it; `--fix` has to remove it *and* the processes it was supervising.
#
# The processes are the part that is easy to get wrong. A `SIGKILL` to the
# daemon does not end what it started — the kernel reparents them — so a
# `--fix` that only signals the daemon leaves a second copy of the service
# running next to the one the survivor owns. This test counts copies.
#
# Usage: scripts/test-doctor-orphan.sh [path-to-pm3]

set -euo pipefail

cd "$(dirname "$0")/.."

PM3=${1:-_build/native/release/build/cmd/pm3/pm3.exe}

if [ ! -x "$PM3" ]; then
  echo "not executable: $PM3" >&2
  echo "build it first: moon build --target native --release" >&2
  exit 1
fi

work=$(mktemp -d)
# The script name carries the pid, so `pgrep -f` cannot match the shell running
# this test and the counts stay honest.
app="$work/app-$$.sh"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$app"
chmod +x "$app"

export PM3_HOME="$work/home"
trap 'pkill -f "God Daemon ($PM3_HOME)" 2>/dev/null || true; pkill -f "$app" 2>/dev/null || true; rm -rf "$work"' EXIT

daemon_count() {
  # The daemon rewrites its argv into `PM3 vX.Y.Z: God Daemon (<home>)`, so the
  # home directory is what identifies the daemons belonging to this test.
  pgrep -f -c "God Daemon \($PM3_HOME\)" || true
}

# How many copies of the app are running. The full path is quoted, so only the
# copies carry it — the shell running this test does not, because `$app` lives
# in a variable.
app_count() {
  pgrep -f -c -- "$app" || true
}

status_of_s1() {
  "$PM3" list 2>/dev/null | grep ' s1 ' | grep -oE 'online|stopped|launching' | head -1
}

fail() {
  echo "FAIL: $*" >&2
  echo "daemons: $(daemon_count)  copies: $(app_count)  state: $(status_of_s1)" >&2
  ls -la "$PM3_HOME" >&2 || true
  echo "--- pm3 list ---" >&2
  "$PM3" list >&2 || true
  exit 1
}

# A daemon started by hand is exactly the case the start lock cannot cover: an
# older build, or an operator, can always start another one.
start_daemon() {
  local want=$1
  "$PM3" daemon "PM3 v$("$PM3" version | awk '{print $2}'): God Daemon ($PM3_HOME)" \
    >/dev/null 2>&1 &
  # `disown`: the daemon is killed on purpose later, and bash would otherwise
  # print a "Killed" line for a job this script stopped expecting to end.
  disown $!
  for _ in $(seq 50); do
    [ "$(daemon_count)" -ge "$want" ] && return 0
    sleep 0.1
  done
  fail "expected $want daemon(s), found $(daemon_count)"
}

echo "orphan test in $PM3_HOME"

# --- The orphan owns the app, the survivor has it stopped --------------------
# This is what a crash looks like: the daemon that started the service is not
# the one the client reaches, so the survivor copied `stopped` out of the dump.
start_daemon 1
sleep 1
"$PM3" start "$app" --name s1 >/dev/null 2>&1 || fail "could not start s1"
for _ in $(seq 50); do
  [ "$(status_of_s1)" = "online" ] && break
  sleep 0.1
done
[ "$(status_of_s1)" = "online" ] || fail "s1 did not come online"

copies_before=$(app_count)
[ "$copies_before" -ge 1 ] || fail "the app is not running at all"

# Now the orphan: the app above belongs to a daemon the client no longer
# reaches.
start_daemon 2
sleep 1
survivor_status=$(status_of_s1)
[ "$survivor_status" = "stopped" ] ||
  fail "the survivor sees s1 as '$survivor_status', expected the dump's stopped"

"$PM3" doctor >/dev/null 2>&1 && fail "doctor found nothing while two daemons run"

# Let the survivor start its own copy first, which is the harder case: one copy
# is supervised and one is a stray, and only the stray may be signalled.
"$PM3" resurrect >/dev/null 2>&1 || true
sleep 2

"$PM3" doctor --fix >/dev/null 2>&1 || fail "--fix reported a problem"

for _ in $(seq 100); do
  [ "$(daemon_count)" -eq 1 ] && [ "$(app_count)" -le "$copies_before" ] && break
  sleep 0.1
done
sleep 1

left=$(daemon_count)
[ "$left" -eq 1 ] || fail "--fix left $left daemon(s)"
copies_after=$(app_count)
[ "$copies_after" -le "$copies_before" ] ||
  fail "copies went from $copies_before to $copies_after"
[ "$copies_after" -ge 1 ] || fail "--fix ended the service without restarting it"

"$PM3" doctor >/dev/null 2>&1 || fail "doctor is still unhappy after --fix"
[ ! -e "$PM3_HOME/.pm3-doctor-probe" ] || fail "--fix left its probe file behind"

"$PM3" kill >/dev/null 2>&1 || true
for _ in $(seq 50); do
  [ "$(daemon_count)" -eq 0 ] && break
  sleep 0.1
done
[ "$(daemon_count)" -eq 0 ] || fail "pm3 kill left a daemon behind"

echo "OK: --fix removed the orphan and ended the ${copies_before}-copy stray"
