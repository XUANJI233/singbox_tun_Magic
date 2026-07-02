# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

# Validate the freshly rendered config BEFORE touching the running process,
# then restart. sing-box has no in-process hot reload, so this is the safe
# "apply my edits" path: a broken edit fails the check and leaves the current
# process running instead of stopping into a dead service.
reload_service() {
  load_settings
  if [ "$SBMAGIC_ENABLED" != "true" ]; then
    echo "module disabled -- nothing to reload"
    return 0
  fi
  check_config || die "config check failed -- keeping current process running"
  mark_prechecked_config || true
  restart_service
}

# Roll back to the last config that survived a full watchdog interval
# (see watchdog()) and start it directly, bypassing render_config. Used
# both by the crash-loop guard and as a manual "undo" from the WebUI.

rollback_service_locked() {
  stop_service_locked
  cp -f "$LAST_GOOD_FILE" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  if ! "$SING_BOX" check -D "$DATA_DIR" -c "$CONFIG_FILE"; then
    die "last-good config no longer passes check (binary upgrade?)"
  fi
  apply_api_firewall
  mv -f "$RUN_LOG" "$RUN_LOG.old" 2>/dev/null
  "$SING_BOX" run -D "$DATA_DIR" -c "$CONFIG_FILE" >> "$RUN_LOG" 2>&1 &
  echo $! > "$PID_FILE"
  echo "$SING_BOX" > "$PROCESS_FILE"
  sleep 1
  if ! pid_alive; then
    remove_api_firewall
    tail -80 "$RUN_LOG" 2>/dev/null
    die "rollback start failed too -- check logs, binary, and connectivity"
  fi
  log "rolled back to last-good config, pid=$(cat "$PID_FILE")"
  [ "$SBMAGIC_MONITOR_CHILD" = "true" ] || ensure_watchdog
  sync_netwatch
  status
}

rollback_service() {
  load_settings
  prepare_process_binary
  [ -f "$LAST_GOOD_FILE" ] || die "no last-good config snapshot yet -- nothing to roll back to"
  if [ "$SBMAGIC_WATCHDOG" = "true" ] && [ "$SBMAGIC_MONITOR_CHILD" != "true" ] && watchdog_alive; then
    : > "$SUPERVISOR_ROLLBACK_FILE"
    stop_service
    if wait_for_service_start; then
      status
      return 0
    fi
    tail -80 "$CONTROL_LOG" 2>/dev/null
    return 1
  fi
  acquire_start_lock || die "another start is in progress -- try again"
  trap 'release_start_lock' EXIT INT TERM HUP
  rollback_service_locked
  trap - EXIT INT TERM HUP
  release_start_lock
}

enable_service() {
  load_settings
  if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '^SBMAGIC_ENABLED=' "$SETTINGS_FILE"; then
      sed -i 's/^SBMAGIC_ENABLED=.*/SBMAGIC_ENABLED=true/' "$SETTINGS_FILE"
    else
      echo 'SBMAGIC_ENABLED=true' >> "$SETTINGS_FILE"
    fi
  fi
  echo "enabled"
}

disable_service() {
  mkdirs
  if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '^SBMAGIC_ENABLED=' "$SETTINGS_FILE"; then
      sed -i 's/^SBMAGIC_ENABLED=.*/SBMAGIC_ENABLED=false/' "$SETTINGS_FILE"
    else
      echo 'SBMAGIC_ENABLED=false' >> "$SETTINGS_FILE"
    fi
  else
    echo 'SBMAGIC_ENABLED=false' > "$SETTINGS_FILE"
  fi
  stop_all_service
  echo "disabled"
}
