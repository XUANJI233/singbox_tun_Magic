#!/system/bin/sh

BENCH_DIR="${BENCH_DIR:-/data/local/tmp/sbmagic-bench}"
DATA_DIR="${SBMAGIC_DATA_DIR:-/data/adb/singbox_tun_Magic}"
CTL="$DATA_DIR/magicctl"
SINGBOX="$DATA_DIR/bin/netd-helper"
HEV="$BENCH_DIR/hev-linux-arm64"
XRAY="$BENCH_DIR/xray"

APP_PACKAGE="${APP_PACKAGE:-io.github.forkmaintainers.iceraven}"
APP_UID="${APP_UID:-}"
SERVER_IP="${SERVER_IP:-192.168.1.201}"
URL="${URL:-http://192.168.1.201:18081/32m.bin}"
RUNS="${RUNS:-8}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
TABLE_ID="${TABLE_ID:-2024}"
# Destination-only redirect: no uid, no mark, no iptables mangle at all.
# `ip rule add to $SERVER_IP lookup $TABLE_ID` is a plain policy-routing
# match on destination address -- it never goes through fwmarkd's per-app
# network-selection layer (that layer only rewrites the mark/route decision
# for a uid's *outbound network choice*, it has no opinion once a rule
# unconditionally names a destination). This is what actually got real SYNs
# into HEV's tun on-device; the official-README uid/fwmark-bypass approach
# never did (see docs/diagnostics/2026-07-01-disconnects.md). It also means
# HEV's own upstream dial to 127.0.0.1:$SOCKS_PORT never needs a bypass rule
# in the first place -- loopback is resolved by the unconditional `lookup
# local` rule (pref 0) long before this pref is ever consulted.
RULE_PREF="${RULE_PREF:-100}"
TUN_NAME="${TUN_NAME:-tun_hev0}"
TUN_ADDR="${TUN_ADDR:-198.18.0.1}"
TUN_CIDR="${TUN_CIDR:-198.18.0.1/15}"

mkdir -p "$BENCH_DIR" "$DATA_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DATA_DIR/logs/tun-energy-compare-$STAMP.log"
STATS_FILE="$BENCH_DIR/proc-stats.$STAMP"
: > "$LOG"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

read_first_file() {
  for f in "$@"; do
    [ -r "$f" ] && { cat "$f" 2>/dev/null; return; }
  done
  printf 'n/a'
}

battery_snapshot() {
  label="$1"
  status="$(read_first_file /sys/class/power_supply/battery/status)"
  capacity="$(read_first_file /sys/class/power_supply/battery/capacity)"
  current_now="$(read_first_file /sys/class/power_supply/battery/current_now)"
  charge_counter="$(read_first_file /sys/class/power_supply/battery/charge_counter)"
  temp="$(read_first_file /sys/class/power_supply/battery/temp)"
  usb_online="$(read_first_file /sys/class/power_supply/usb/online /sys/class/power_supply/usb_pd/online)"
  ac_online="$(read_first_file /sys/class/power_supply/ac/online /sys/class/power_supply/dc/online)"
  log "battery label=$label status=$status capacity=$capacity current_now_uA=$current_now charge_counter_uAh=$charge_counter temp_decic=$temp usb_online=$usb_online ac_online=$ac_online"
}

proc_total_jiffies() {
  pid="$1"
  [ -r "/proc/$pid/stat" ] || { echo 0; return; }
  awk '{ print $14 + $15 }' "/proc/$pid/stat" 2>/dev/null || echo 0
}

proc_brief() {
  label="$1"
  pid="$2"
  if [ ! -r "/proc/$pid/status" ]; then
    log "proc label=$label pid=$pid alive=false"
    return
  fi
  rss="$(awk '/VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
  threads="$(awk '/Threads:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
  oom="$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)"
  jiffies="$(proc_total_jiffies "$pid")"
  log "proc label=$label pid=$pid alive=true rss_kb=${rss:-0} threads=${threads:-0} oom_score_adj=${oom:-n/a} cpu_jiffies=$jiffies"
}

link_snapshot() {
  label="$1"
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    log "link label=$label name=$TUN_NAME"
    ip addr show "$TUN_NAME" >> "$LOG" 2>&1 || true
    ip -s link show "$TUN_NAME" >> "$LOG" 2>&1 || true
  fi
}

remember_proc_start() {
  label="$1"
  pid="$2"
  before="$(proc_total_jiffies "$pid")"
  printf '%s %s %s\n' "$label" "$pid" "$before" >> "$STATS_FILE"
  proc_brief "$label.before" "$pid"
}

report_proc_delta() {
  while read label pid before; do
    [ -n "$label" ] || continue
    after="$(proc_total_jiffies "$pid")"
    delta=$((after - before))
    [ "$delta" -lt 0 ] && delta=0
    log "cpu_delta label=$label pid=$pid delta_jiffies=$delta"
    proc_brief "$label.after" "$pid"
  done < "$STATS_FILE"
  : > "$STATS_FILE"
}

resolve_app_uid() {
  [ -n "$APP_UID" ] && return
  line="$(cmd package list packages -U "$APP_PACKAGE" 2>/dev/null | head -n 1)"
  APP_UID="$(printf '%s\n' "$line" | sed -n 's/.* uid:\([0-9][0-9]*\).*/\1/p')"
  [ -n "$APP_UID" ] || {
    log "missing uid for package=$APP_PACKAGE"
    exit 2
  }
}

kill_pid() {
  pid="$1"
  [ -n "$pid" ] || return
  kill "$pid" 2>/dev/null || true
  sleep 0.2
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
}

cleanup_bench() {
  while ip rule del pref "$RULE_PREF" 2>/dev/null; do :; done
  ip route flush table "$TABLE_ID" 2>/dev/null || true
  ip link set "$TUN_NAME" down 2>/dev/null || true

  for f in "$BENCH_DIR/core.pid" "$BENCH_DIR/hev.pid" "$BENCH_DIR/xray.pid"; do
    [ -f "$f" ] && kill_pid "$(cat "$f" 2>/dev/null)"
    rm -f "$f"
  done

  for pattern in "$BENCH_DIR/hev-linux-arm64" "$BENCH_DIR/xray" "$SINGBOX run -D $BENCH_DIR"; do
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    for pid in $pids; do
      [ "$pid" = "$$" ] && continue
      kill_pid "$pid"
    done
  done
}

restore_module() {
  cleanup_bench
  if [ "$RESTORE_MODULE" = "true" ]; then
    log "restore module service"
    "$CTL" start >> "$LOG" 2>&1 || true
  fi
}

wait_for_file_pid_alive() {
  f="$1"
  i=0
  while [ "$i" -lt 20 ]; do
    pid="$(cat "$f" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    i=$((i + 1))
    sleep 0.2
  done
  return 1
}

wait_for_tun() {
  i=0
  while [ "$i" -lt 30 ]; do
    ip link show "$TUN_NAME" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.2
  done
  return 1
}

wait_for_socks() {
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null --socks5-hostname "127.0.0.1:$SOCKS_PORT" --connect-timeout 2 --max-time 8 "$URL" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}

write_singbox_socks_config() {
  cat > "$BENCH_DIR/singbox-socks.json" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "$BENCH_DIR/singbox-socks.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": $SOCKS_PORT
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "direct"
  }
}
EOF
}

write_xray_socks_config() {
  cat > "$BENCH_DIR/xray-socks.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$BENCH_DIR/xray-access.log",
    "error": "$BENCH_DIR/xray-error.log"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

write_hev_config() {
  cat > "$BENCH_DIR/hev.yml" <<EOF
tunnel:
  name: $TUN_NAME
  mtu: 1500
  multi-queue: true
  ipv4: $TUN_ADDR

socks5:
  port: $SOCKS_PORT
  address: 127.0.0.1
  udp: 'udp'
  tcp-fastopen: true

misc:
  log-file: $BENCH_DIR/hev.log
  log-level: warn
EOF
}

start_singbox_socks() {
  write_singbox_socks_config
  rm -f "$BENCH_DIR/singbox-socks.log" "$BENCH_DIR/singbox-socks.stdout.log"
  "$SINGBOX" run -D "$BENCH_DIR" -c "$BENCH_DIR/singbox-socks.json" >> "$BENCH_DIR/singbox-socks.stdout.log" 2>&1 &
  echo "$!" > "$BENCH_DIR/core.pid"
  wait_for_file_pid_alive "$BENCH_DIR/core.pid" || return 1
  wait_for_socks || return 1
}

start_xray_socks() {
  write_xray_socks_config
  rm -f "$BENCH_DIR/xray-access.log" "$BENCH_DIR/xray-error.log" "$BENCH_DIR/xray.stdout.log"
  "$XRAY" run -config "$BENCH_DIR/xray-socks.json" >> "$BENCH_DIR/xray.stdout.log" 2>&1 &
  echo "$!" > "$BENCH_DIR/xray.pid"
  wait_for_file_pid_alive "$BENCH_DIR/xray.pid" || return 1
  wait_for_socks || return 1
}

start_hev() {
  write_hev_config
  rm -f "$BENCH_DIR/hev.log" "$BENCH_DIR/hev.stdout.log"
  "$HEV" "$BENCH_DIR/hev.yml" >> "$BENCH_DIR/hev.stdout.log" 2>&1 &
  echo "$!" > "$BENCH_DIR/hev.pid"
  wait_for_file_pid_alive "$BENCH_DIR/hev.pid" || return 1
  wait_for_tun || return 1
  echo 0 > "/proc/sys/net/ipv4/conf/$TUN_NAME/rp_filter" 2>/dev/null || true
  echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
  ip addr add "$TUN_CIDR" dev "$TUN_NAME" 2>/dev/null || true
  ip link set "$TUN_NAME" up 2>/dev/null || true
  ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
  ip rule add to "$SERVER_IP" lookup "$TABLE_ID" pref "$RULE_PREF" 2>/dev/null || true
  ip route flush cache 2>/dev/null || true
  log "rule/route confirm:"
  ip rule show >> "$LOG" 2>&1 || true
  ip route get "$SERVER_IP" >> "$LOG" 2>&1 || true
}

bench_samples() {
  mode="$1"
  as_uid="$2"
  cmd="curl -sS -o /dev/null --connect-timeout 5 --max-time 40 -w 'code=%{http_code} total=%{time_total} speed=%{speed_download} size=%{size_download}' '$URL'"
  i=1
  while [ "$i" -le "$RUNS" ]; do
    if [ -n "$as_uid" ]; then
      out="$(su "$as_uid" -c "$cmd" 2>&1)"
    else
      # hev modes redirect by destination, not uid, so a plain (root) curl
      # is enough -- the destination rule doesn't care who owns the socket.
      out="$(eval "$cmd" 2>&1)"
    fi
    rc=$?
    log "sample mode=$mode run=$i rc=$rc $out"
    i=$((i + 1))
    sleep 0.2
  done
}

bench_mode() {
  mode="$1"
  procs="$2"
  as_uid="$3"
  log "mode_start $mode"
  battery_snapshot "$mode.before"
  : > "$STATS_FILE"
  for entry in $procs; do
    label="${entry%%:*}"
    pid="${entry#*:}"
    remember_proc_start "$mode.$label" "$pid"
  done
  link_snapshot "$mode.before"
  bench_samples "$mode" "$as_uid"
  link_snapshot "$mode.after"
  battery_snapshot "$mode.after"
  report_proc_delta
  log "mode_end $mode"
}

mode_native() {
  "$CTL" status >> "$LOG" 2>&1 || true
  if ! "$CTL" status 2>/dev/null | grep -q '^running=true'; then
    "$CTL" start >> "$LOG" 2>&1 || true
  fi
  sleep 1
  pid="$("$CTL" status 2>/dev/null | sed -n 's/^pid=//p' | head -n 1)"
  [ -n "$pid" ] || { log "native missing module pid"; return 1; }
  ip route get "$SERVER_IP" uid "$APP_UID" >> "$LOG" 2>&1 || true
  bench_mode "native-singbox-tun" "core:$pid" "$APP_UID"
}

mode_hev_singbox() {
  log "stop module for hev-singbox"
  "$CTL" stop >> "$LOG" 2>&1 || true
  sleep 1
  cleanup_bench
  start_singbox_socks || { log "hev-singbox core start failed"; return 1; }
  start_hev || { log "hev-singbox hev start failed"; return 1; }
  core_pid="$(cat "$BENCH_DIR/core.pid" 2>/dev/null)"
  hev_pid="$(cat "$BENCH_DIR/hev.pid" 2>/dev/null)"
  bench_mode "hev-singbox" "core:$core_pid hev:$hev_pid" ""
}

mode_hev_xray() {
  cleanup_bench
  start_xray_socks || { log "hev-xray core start failed"; return 1; }
  start_hev || { log "hev-xray hev start failed"; return 1; }
  core_pid="$(cat "$BENCH_DIR/xray.pid" 2>/dev/null)"
  hev_pid="$(cat "$BENCH_DIR/hev.pid" 2>/dev/null)"
  bench_mode "hev-xray" "core:$core_pid hev:$hev_pid" ""
}

RESTORE_MODULE="false"
trap restore_module EXIT INT TERM

resolve_app_uid
log "bench_start log=$LOG package=$APP_PACKAGE uid=$APP_UID url=$URL runs=$RUNS"
log "device model=$(getprop ro.product.model) android=$(getprop ro.build.version.release) abi=$(getprop ro.product.cpu.abi)"
log "binaries singbox=$($SINGBOX version 2>/dev/null | head -n 1) xray=$($XRAY version 2>/dev/null | head -n 1) hev=$($HEV --version 2>&1 | grep -m1 '^Version:' | sed 's/^Version: //')"

cleanup_bench
mode_native

RESTORE_MODULE="true"
mode_hev_singbox
cleanup_bench
mode_hev_xray

restore_module
trap - EXIT INT TERM
log "bench_done log=$LOG"
