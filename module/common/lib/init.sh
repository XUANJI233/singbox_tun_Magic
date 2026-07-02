# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

start_init_service() {
  command -v setprop >/dev/null 2>&1 || return 1
  rm -f "$INITD_SEEN_FILE"
  setprop ctl.start netd_helper 2>/dev/null || return 1
  return 0
}

wait_for_init_service_entry() {
  i=0
  while [ "$i" -lt 8 ]; do
    [ -f "$INITD_SEEN_FILE" ] && return 0
    pid_alive && return 0
    watchdog_alive && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

initd() {
  mkdirs
  echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$INITD_SEEN_FILE"
  chmod 600 "$INITD_SEEN_FILE" 2>/dev/null
  log "init service entry"
  load_settings
  if [ "$SBMAGIC_BOOT_START" != "true" ]; then
    log "init service exiting: boot start disabled"
    echo "boot start disabled"
    return 0
  fi
  if [ "$SBMAGIC_ENABLED" != "true" ]; then
    log "init service exiting: module disabled"
    echo "module disabled in $SETTINGS_FILE"
    return 0
  fi
  if [ "$SBMAGIC_WATCHDOG" = "true" ]; then
    log "init service running watchdog in foreground"
    watchdog
    return $?
  fi
  log "init service running one-shot core in foreground"
  initd_direct
}

boot() {
  mkdirs
  load_settings
  if [ "$SBMAGIC_BOOT_START" != "true" ]; then
    log "boot start disabled"
    echo "boot start disabled"
    return 0
  fi
  start_service
}

initd_direct() {
  acquire_start_lock || { echo "another service operation is already in progress"; return 1; }
  trap 'release_start_lock' EXIT INT TERM HUP
  start_service_locked
  rc=$?
  trap - EXIT INT TERM HUP
  release_start_lock
  [ "$rc" -eq 0 ] || return "$rc"

  pid="$(cat "$PID_FILE" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  wait "$pid" 2>/dev/null
  current_pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ "$current_pid" = "$pid" ]; then
    rm -f "$PID_FILE" "$PROCESS_FILE"
    remove_api_firewall
  fi
}

boot_dispatch() {
  mkdirs
  load_settings
  if [ "$SBMAGIC_BOOT_START" != "true" ]; then
    log "boot dispatch: boot start disabled"
    echo "boot start disabled"
    return 0
  fi
  if pid_alive || watchdog_alive; then
    log "boot dispatch: service already active"
    status
    return 0
  fi
  if [ "$SBMAGIC_INIT_SERVICE" = "true" ]; then
    log "boot dispatch: trying init service fallback"
    if start_init_service && wait_for_init_service_entry; then
      log "boot dispatch: init service handled boot"
      return 0
    fi
    log "boot dispatch: init service unavailable, falling back to direct boot"
  fi
  boot
}
