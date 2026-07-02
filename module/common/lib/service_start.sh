# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

start_service_locked() {
  mkdirs
  load_settings
  if [ "$SBMAGIC_ENABLED" != "true" ]; then
    echo "module disabled in $SETTINGS_FILE"
    return 0
  fi
  if pid_alive; then
    echo "sing-box already running: $(cat "$PID_FILE")"
    return 0
  fi
  if consume_prechecked_config; then
    log "using prechecked config; skipped duplicate start check"
  elif ! check_config; then
    die "config check failed"
  fi
  ensure_api_env
  apply_tcp_congestion_control
  apply_api_firewall
  mv -f "$RUN_LOG" "$RUN_LOG.old" 2>/dev/null
  "$SING_BOX" run -D "$DATA_DIR" -c "$CONFIG_FILE" >> "$RUN_LOG" 2>&1 &
  echo $! > "$PID_FILE"
  echo "$SING_BOX" > "$PROCESS_FILE"
  sleep 1
  if ! pid_alive; then
    remove_api_firewall
    tail -80 "$RUN_LOG" 2>/dev/null
    die "sing-box failed to start"
  fi
  child_pid="$(cat "$PID_FILE")"
  apply_oom_score_adj "$child_pid" "sing-box"
  log "started sing-box pid=$child_pid"
  if ! wait_for_runtime_ready; then
    log "sing-box pid=$child_pid started but API/TUN not ready yet"
  fi
  [ "$SBMAGIC_MONITOR_CHILD" = "true" ] || ensure_watchdog
  sync_netwatch
  status
}

start_service() {
  load_settings
  if [ "$SBMAGIC_ENABLED" != "true" ]; then
    echo "module disabled in $SETTINGS_FILE"
    return 0
  fi
  if [ "$SBMAGIC_WATCHDOG" = "true" ] && [ "$SBMAGIC_MONITOR_CHILD" != "true" ]; then
    ensure_watchdog
    if wait_for_service_start; then
      status
      return 0
    fi
    tail -80 "$CONTROL_LOG" 2>/dev/null
    return 1
  fi
  acquire_start_lock || { echo "another service operation is already in progress"; return 1; }
  trap 'release_start_lock' EXIT INT TERM HUP
  start_service_locked
  rc=$?
  trap - EXIT INT TERM HUP
  release_start_lock
  return "$rc"
}

restart_service() {
  load_settings
  if [ "$SBMAGIC_WATCHDOG" = "true" ] && [ "$SBMAGIC_MONITOR_CHILD" != "true" ] && watchdog_alive; then
    : > "$SUPERVISOR_RESTART_FILE"
    stop_service
    if wait_for_service_start; then
      status
      return 0
    fi
    tail -80 "$CONTROL_LOG" 2>/dev/null
    return 1
  fi
  acquire_start_lock || { echo "another service operation is already in progress"; return 1; }
  trap 'release_start_lock' EXIT INT TERM HUP
  stop_service_locked
  start_service_locked
  rc=$?
  trap - EXIT INT TERM HUP
  release_start_lock
  return "$rc"
}

# Stop the watchdog loop. Kept separate from stop_service() because the
# internal stop/start paths (restart, rollback, watchdog self-recovery)
# must NOT take the watchdog down -- only the user-facing stop/disable do.
# The "$wpid" != "$$" guard means the watchdog calling disable_service on
# itself (crash-loop shutdown) won't SIGTERM itself mid-cleanup.

sync_netwatch() {
  if [ "$SBMAGIC_NETWORK_WATCH" != "true" ]; then
    stop_netwatch
    return 0
  fi
  command -v ip >/dev/null 2>&1 || {
    stop_netwatch
    log "network watch skipped: ip command unavailable"
    return 0
  }
  if netwatch_alive; then
    return 0
  fi
  rm -f "$NETWATCH_PID_FILE"
  "$0" netwatch >/dev/null 2>&1 &
}
