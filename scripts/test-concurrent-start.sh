#!/usr/bin/env bash
#
# End-to-end check that concurrent clients start exactly one daemon.
#
# pm3 has no fixed socket path: the daemon binds an arbitrary port and
# publishes it in `daemon.port`. Two clients that both miss that file would
# both spawn a daemon, and the loser would keep supervising processes while
# being invisible to `pm3 list` and unreachable by `pm3 kill`. The unit tests
# cover the lock itself; this test covers the thing the lock is for, against
# the real binary.
#
# Usage: scripts/test-concurrent-start.sh [path-to-pm3]

set -euo pipefail

cd "$(dirname "$0")/.."

PM3=${1:-_build/native/release/build/cmd/pm3/pm3.exe}
CLIENTS=${PM3_TEST_CLIENTS:-8}

if [ ! -x "$PM3" ]; then
  echo "not executable: $PM3" >&2
  echo "build it first: moon build --target native --release" >&2
  exit 1
fi

work=$(mktemp -d)
export PM3_HOME="$work/home"
trap 'pkill -f "God Daemon ($PM3_HOME)" 2>/dev/null || true; rm -rf "$work"' EXIT

daemon_count() {
  # The daemon rewrites its argv into `PM3 vX.Y.Z: God Daemon (<home>)`, so the
  # home directory is what identifies the daemons belonging to this test.
  # `pgrep` rather than `ps | grep`: the grep process carries the pattern in
  # its own argv and would count itself, making a single daemon look like two.
  pgrep -f -c "God Daemon \($PM3_HOME\)" || true
}

fail() {
  echo "FAIL: $*" >&2
  echo "daemons: $(daemon_count)" >&2
  echo "state: $PM3_HOME" >&2
  ls -la "$PM3_HOME" >&2 || true
  exit 1
}

echo "racing $CLIENTS clients against $PM3_HOME"
for _ in $(seq "$CLIENTS"); do
  "$PM3" list >/dev/null 2>&1 &
done
wait

# A daemon that is still publishing its port is not yet visible to `ps` with a
# test home, and one that lost the race exits on its own, so let things settle.
for _ in $(seq 50); do
  running=$(daemon_count)
  [ "$running" -ge 1 ] && break
  sleep 0.1
done
sleep 1

running=$(daemon_count)
[ "$running" -eq 1 ] || fail "expected 1 daemon, found $running"

# The survivor must actually answer, otherwise "one daemon" could just mean
# "one broken daemon".
"$PM3" list >/dev/null 2>&1 || fail "the remaining daemon does not answer"

# The start lock must not be left behind.
[ ! -e "$PM3_HOME/daemon.lock" ] || fail "daemon.lock was left behind"

"$PM3" kill >/dev/null 2>&1 || true
for _ in $(seq 50); do
  [ "$(daemon_count)" -eq 0 ] && break
  sleep 0.1
done

leftover=$(daemon_count)
[ "$leftover" -eq 0 ] || fail "pm3 kill left $leftover daemon(s) running"

echo "OK: $CLIENTS clients started 1 daemon, and pm3 kill removed it"
