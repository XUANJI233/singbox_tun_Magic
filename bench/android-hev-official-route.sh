#!/system/bin/sh

BENCH_DIR="${BENCH_DIR:-/data/local/tmp/sbmagic-bench}"
DATA_DIR="${SBMAGIC_DATA_DIR:-/data/adb/singbox_tun_Magic}"
CTL="$DATA_DIR/magicctl"
HEV="$BENCH_DIR/hev-linux-arm64"

SOCKS_HOST="${SOCKS_HOST:-192.168.1.201}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
URL="${URL:-http://192.168.1.201:18081/32m.bin}"
SERVER_IP="${SERVER_IP:-192.168.1.201}"
RUNS="${RUNS:-1}"
HEV_STRACE="${HEV_STRACE:-false}"

TUN_NAME="${TUN_NAME:-tun_hev_off}"
TUN_ADDR="${TUN_ADDR:-198.18.0.1}"
TUN_CIDR="${TUN_CIDR:-198.18.0.1/15}"
TABLE_ID="${TABLE_ID:-2026}"
HEV_SOCKS_MARK="${HEV_SOCKS_MARK:-438}"
HEV_SOCKS_MARK_MATCH="${HEV_SOCKS_MARK_MATCH:-$HEV_SOCKS_MARK}"
HEV_BYPASS_PREF="${HEV_BYPASS_PREF:-10}"
HEV_ROUTE_PREF="${HEV_ROUTE_PREF:-20}"

mkdir -p "$BENCH_DIR" "$DATA_DIR/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DATA_DIR/logs/hev-official-route-$STAMP.log"
: > "$LOG"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

proc_total_jiffies() {
  pid="$1"
  [ -r "/proc/$pid/stat" ] || { echo 0; return; }
  awk '{ print $14 + $15 }' "/proc/$pid/stat" 2>/dev/null || echo 0
}

kill_pid() {
  pid="$1"
  [ -n "$pid" ] || return
  kill "$pid" 2>/dev/null || true
  sleep 0.2
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
}

cleanup() {
  while ip rule del pref "$HEV_BYPASS_PREF" 2>/dev/null; do :; done
  while ip -6 rule del pref "$HEV_BYPASS_PREF" 2>/dev/null; do :; done
  while ip rule del pref "$HEV_ROUTE_PREF" 2>/dev/null; do :; done
  while ip -6 rule del pref "$HEV_ROUTE_PREF" 2>/dev/null; do :; done
  ip route flush table "$TABLE_ID" 2>/dev/null || true
  ip -6 route flush table "$TABLE_ID" 2>/dev/null || true
  ip link set "$TUN_NAME" down 2>/dev/null || true
  [ -f "$BENCH_DIR/hev-official.pid" ] && kill_pid "$(cat "$BENCH_DIR/hev-official.pid" 2>/dev/null)"
  rm -f "$BENCH_DIR/hev-official.pid"
}

restore() {
  cleanup
  "$CTL" start >> "$LOG" 2>&1 || true
}

wait_for_tun() {
  i=0
  while [ "$i" -lt 50 ]; do
    ip link show "$TUN_NAME" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

write_hev_config() {
  cat > "$BENCH_DIR/hev-official.yml" <<EOF
tunnel:
  name: $TUN_NAME
  mtu: 1500
  multi-queue: true
  ipv4: $TUN_ADDR

socks5:
  port: $SOCKS_PORT
  address: $SOCKS_HOST
  udp: 'udp'
  mark: $HEV_SOCKS_MARK
  tcp-fastopen: true

misc:
  log-file: $BENCH_DIR/hev-official.log
  log-level: info
EOF
}

snapshot_link() {
  label="$1"
  log "link label=$label"
  ip addr show "$TUN_NAME" >> "$LOG" 2>&1 || true
  ip -s link show "$TUN_NAME" >> "$LOG" 2>&1 || true
}

trap restore EXIT INT TERM

log "official_route_start url=$URL socks=$SOCKS_HOST:$SOCKS_PORT hev=$($HEV --version 2>&1 | grep -m1 '^Version:' | sed 's/^Version: //')"
log "stop module"
"$CTL" stop >> "$LOG" 2>&1 || true
sleep 1
cleanup
write_hev_config
rm -f "$BENCH_DIR/hev-official.log" "$BENCH_DIR/hev-official.stdout.log"
if [ "$HEV_STRACE" = "true" ]; then
  STRACE_PREFIX="$BENCH_DIR/hev-official-strace.$STAMP"
  strace -ff -tt -e trace=setsockopt,connect,openat,ioctl -o "$STRACE_PREFIX" "$HEV" "$BENCH_DIR/hev-official.yml" >> "$BENCH_DIR/hev-official.stdout.log" 2>&1 &
  log "strace_prefix=$STRACE_PREFIX"
else
  "$HEV" "$BENCH_DIR/hev-official.yml" >> "$BENCH_DIR/hev-official.stdout.log" 2>&1 &
fi
echo "$!" > "$BENCH_DIR/hev-official.pid"
wait_for_tun || { log "tun not ready"; exit 1; }

echo 0 > "/proc/sys/net/ipv4/conf/$TUN_NAME/rp_filter" 2>/dev/null || true
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
ip addr add "$TUN_CIDR" dev "$TUN_NAME" 2>/dev/null || true
ip link set "$TUN_NAME" up 2>/dev/null || true

ip rule add fwmark "$HEV_SOCKS_MARK_MATCH" lookup main pref "$HEV_BYPASS_PREF" 2>/dev/null || true
ip -6 rule add fwmark "$HEV_SOCKS_MARK_MATCH" lookup main pref "$HEV_BYPASS_PREF" 2>/dev/null || true
ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
ip rule add lookup "$TABLE_ID" pref "$HEV_ROUTE_PREF" 2>/dev/null || true

log "rules"
ip rule show >> "$LOG" 2>&1 || true
log "route_unmarked_target"
ip route get "$SERVER_IP" >> "$LOG" 2>&1 || true
log "route_marked_socks"
ip route get "$SOCKS_HOST" mark "$HEV_SOCKS_MARK" >> "$LOG" 2>&1 || true

pid="$(cat "$BENCH_DIR/hev-official.pid" 2>/dev/null)"
before="$(proc_total_jiffies "$pid")"
snapshot_link before
i=1
while [ "$i" -le "$RUNS" ]; do
  out="$(curl -sS -o /dev/null --connect-timeout 5 --max-time 40 -w 'code=%{http_code} total=%{time_total} speed=%{speed_download} size=%{size_download}' "$URL" 2>&1)"
  rc=$?
  log "sample run=$i rc=$rc $out"
  i=$((i + 1))
done
snapshot_link after
after="$(proc_total_jiffies "$pid")"
delta=$((after - before))
[ "$delta" -lt 0 ] && delta=0
log "hev_cpu_delta_jiffies=$delta"
log "hev_log"
cat "$BENCH_DIR/hev-official.log" >> "$LOG" 2>&1 || true
log "official_route_done log=$LOG"

restore
trap - EXIT INT TERM
