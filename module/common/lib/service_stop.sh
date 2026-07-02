# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

stop_pid_file() {
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  saved_process="$(cat "$PROCESS_FILE" 2>/dev/null)"
  if [ -n "$cmdline" ]; then
    module_pid=false
    case "$cmdline" in *"$DATA_DIR"*) module_pid=true ;; esac
    if [ -n "$saved_process" ]; then
      case "$cmdline" in *"$saved_process"*) module_pid=true ;; esac
    fi
    if [ "$module_pid" != "true" ]; then
      log "refusing to stop stale pid=$pid cmdline=$cmdline"
      rm -f "$PID_FILE" "$PROCESS_FILE"
      return 1
    fi
  fi
  kill "$pid" 2>/dev/null
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
  fi
  log "stopped sing-box pid=$pid"
  return 0
}

stop_service_locked() {
  mark_netwatch_own_tun_grace
  stop_last_good_promote_timer
  if ! stop_pid_file && pid_alive; then
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
    fi
    log "stopped sing-box pid=$pid"
  fi
  remove_api_firewall
  rm -f "$PID_FILE" "$PROCESS_FILE"
}

stop_service() {
  acquire_start_lock || { echo "another service operation is already in progress"; return 1; }
  trap 'release_start_lock' EXIT INT TERM HUP
  stop_service_locked
  rc=$?
  trap - EXIT INT TERM HUP
  release_start_lock
  return "$rc"
}

stop_all_service() {
  acquire_start_lock || { echo "another service operation is already in progress"; return 1; }
  trap 'release_start_lock' EXIT INT TERM HUP
  stop_last_good_promote_timer
  stop_init_service
  stop_netwatch
  stop_watchdog
  stop_service_locked
  rc=$?
  restore_tcp_congestion_control
  trap - EXIT INT TERM HUP
  release_start_lock
  return "$rc"
}

stop_watchdog() {
  killed=""
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    wpid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)"
    if [ -n "$wpid" ] && [ "$wpid" != "$$" ]; then
      kill "$wpid" 2>/dev/null
      i=0
      while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 3 ]; do
        sleep 1
        i=$((i + 1))
      done
      kill -0 "$wpid" 2>/dev/null && kill -9 "$wpid" 2>/dev/null
      killed="$killed $wpid"
    fi
    rm -f "$WATCHDOG_PID_FILE"
  fi
  if command -v pgrep >/dev/null 2>&1; then
    for wpid in $(pgrep -f "$DATA_DIR/magicctl watchdog" 2>/dev/null); do
      [ "$wpid" = "$$" ] && continue
      case " $killed " in *" $wpid "*) continue ;; esac
      kill "$wpid" 2>/dev/null
      sleep 1
      kill -0 "$wpid" 2>/dev/null && kill -9 "$wpid" 2>/dev/null
    done
  fi
}

stop_netwatch() {
  killed=""
  if [ -f "$NETWATCH_PID_FILE" ]; then
    npid="$(cat "$NETWATCH_PID_FILE" 2>/dev/null)"
    if [ -n "$npid" ] && [ "$npid" != "$$" ]; then
      kill "$npid" 2>/dev/null
      i=0
      while kill -0 "$npid" 2>/dev/null && [ "$i" -lt 3 ]; do
        sleep 1
        i=$((i + 1))
      done
      kill -0 "$npid" 2>/dev/null && kill -9 "$npid" 2>/dev/null
      killed="$killed $npid"
    fi
    rm -f "$NETWATCH_PID_FILE"
  fi
  stop_netwatch_monitor
  cleanup_netwatch_fifos
  if command -v pgrep >/dev/null 2>&1; then
    for npid in $(pgrep -f "$DATA_DIR/magicctl netwatch" 2>/dev/null); do
      [ "$npid" = "$$" ] && continue
      case " $killed " in *" $npid "*) continue ;; esac
      kill "$npid" 2>/dev/null
      sleep 1
      kill -0 "$npid" 2>/dev/null && kill -9 "$npid" 2>/dev/null
    done
  fi
  stop_netwatch_monitor
  cleanup_netwatch_fifos
}

stop_netwatch_monitor() {
  [ -f "$NETWATCH_MONITOR_PID_FILE" ] || return 0
  mpid="$(cat "$NETWATCH_MONITOR_PID_FILE" 2>/dev/null)"
  rm -f "$NETWATCH_MONITOR_PID_FILE"
  case "$mpid" in ''|*[!0-9]*|$$) return 0 ;; esac
  kill "$mpid" 2>/dev/null || return 0
  i=0
  while kill -0 "$mpid" 2>/dev/null && [ "$i" -lt 3 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill -0 "$mpid" 2>/dev/null && kill -9 "$mpid" 2>/dev/null
}

cleanup_netwatch_fifos() {
  for fifo in "$RUNTIME_DIR"/netwatch.events.*; do
    [ "$fifo" = "$RUNTIME_DIR/netwatch.events.*" ] && continue
    [ -p "$fifo" ] && rm -f "$fifo"
  done
}

stop_init_service() {
  command -v setprop >/dev/null 2>&1 || return 0
  setprop ctl.stop netd_helper 2>/dev/null || true
}
