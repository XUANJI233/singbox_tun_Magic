#!/system/bin/sh
#
# Self-contained teardown. Does NOT depend on magicctl still being present or
# working -- by uninstall time it may already be half-removed. Everything this
# module creates lives under DATA_DIR (configs, runtime, logs, cache, binary)
# or in the module folder itself (removed by the manager), so a clean uninstall
# is: stop the watchdog, let sing-box exit gracefully so it tears down the tun
# interface + auto_route ip-rules/tables it installed, then wipe DATA_DIR.

DATA_DIR=/data/adb/singbox_tun_Magic
PID_FILE="$DATA_DIR/runtime/sing-box.pid"
WPID_FILE="$DATA_DIR/runtime/watchdog.pid"
PROCESS_FILE="$DATA_DIR/runtime/process.path"

is_alive() { kill -0 "$1" 2>/dev/null; }

# 1. Kill the watchdog first, otherwise it could resurrect sing-box while we
#    are tearing it down.
wpid="$(cat "$WPID_FILE" 2>/dev/null)"
[ -n "$wpid" ] && kill "$wpid" 2>/dev/null

# 2. Ask sing-box to exit gracefully. A clean SIGTERM lets it remove the tun
#    device and the auto_route ip-rules/tables -- skipping this can leave the
#    device routing all traffic into a dead tun (no internet) until reboot.
#    Wait up to ~10s, polling, and only SIGKILL if it refuses to leave.
spid="$(cat "$PID_FILE" 2>/dev/null)"
if [ -n "$spid" ] && is_alive "$spid"; then
  kill "$spid" 2>/dev/null
  i=0
  while is_alive "$spid" && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  is_alive "$spid" && kill -9 "$spid" 2>/dev/null
fi

# 3. Catch any stray current binary from our bin dir (lost pid file or custom
#    process name) so nothing keeps holding the tun/routes after the data dir is
#    gone. The pattern is restricted to this module's private bin directory.
BIN="$(cat "$PROCESS_FILE" 2>/dev/null)"
[ -n "$BIN" ] || BIN="$DATA_DIR/bin/netd-helper"
if command -v pgrep >/dev/null 2>&1; then
  for pid in $(pgrep -f "$BIN" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  for pid in $(pgrep -f "$DATA_DIR/bin/" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in $(pgrep -f "$BIN" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
  for pid in $(pgrep -f "$DATA_DIR/bin/" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
fi

# 4. Drop the clash-api firewall chain so no SBMAGIC_API trace is left behind.
#    Best effort: iptables rules don't survive a reboot anyway, this just keeps
#    a running system clean immediately after uninstall.
if command -v iptables >/dev/null 2>&1; then
  while iptables -w -D OUTPUT -j SBMAGIC_API 2>/dev/null; do :; done
  iptables -w -F SBMAGIC_API 2>/dev/null
  iptables -w -X SBMAGIC_API 2>/dev/null
fi

# 5. Remove all persistent state. The module folder is removed by the manager.
rm -rf "$DATA_DIR"
