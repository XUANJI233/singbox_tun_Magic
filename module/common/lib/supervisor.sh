# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

promote_last_good_later() {
  pid="$1"
  interval="$(watchdog_interval_seconds)"
  stop_last_good_promote_timer
  token="$(random_token)"
  "$0" promote-last-good "$pid" "$token" "$interval" >/dev/null 2>&1 &
  echo "$! $token" > "$LAST_GOOD_PROMOTE_PID_FILE"
  chmod 600 "$LAST_GOOD_PROMOTE_PID_FILE" 2>/dev/null || true
}

promote_last_good_after() {
  pid="$1"
  token="$2"
  interval="$3"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$token" ] || return 0
  case "$interval" in ''|*[!0-9]*) interval=300 ;; esac
  sleep "$interval"
  timer_entry="$(cat "$LAST_GOOD_PROMOTE_PID_FILE" 2>/dev/null)"
  case "$timer_entry" in *" $token") ;; *) return 0 ;; esac
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cp -f "$CONFIG_FILE" "$LAST_GOOD_FILE" 2>/dev/null
    echo 0 > "$FAIL_COUNT_FILE" 2>/dev/null
    log "promoted current config to last-good after ${interval}s"
  fi
  timer_entry="$(cat "$LAST_GOOD_PROMOTE_PID_FILE" 2>/dev/null)"
  case "$timer_entry" in *" $token") rm -f "$LAST_GOOD_PROMOTE_PID_FILE" ;; esac
}

stop_last_good_promote_timer() {
  if [ ! -f "$LAST_GOOD_PROMOTE_PID_FILE" ]; then
    stop_stray_last_good_promote_timers
    return 0
  fi
  timer_entry="$(cat "$LAST_GOOD_PROMOTE_PID_FILE" 2>/dev/null)"
  rm -f "$LAST_GOOD_PROMOTE_PID_FILE"
  timer_pid="${timer_entry%% *}"
  case "$timer_pid" in
    ''|*[!0-9]*) ;;
    *)
      [ "$timer_pid" = "$$" ] && timer_pid=""
      [ "$timer_pid" = "$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)" ] && timer_pid=""
      [ "$timer_pid" = "$(cat "$NETWATCH_PID_FILE" 2>/dev/null)" ] && timer_pid=""
      [ "$timer_pid" = "$(cat "$PID_FILE" 2>/dev/null)" ] && timer_pid=""
      if [ -n "$timer_pid" ] && [ -r "/proc/$timer_pid/cmdline" ]; then
        cmdline="$(tr '\000' ' ' < "/proc/$timer_pid/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
          *"$DATA_DIR/magicctl"*"promote-last-good"*|*"magicctl promote-last-good"*) kill -9 "$timer_pid" 2>/dev/null || true ;;
        esac
      fi
      ;;
  esac
  stop_stray_last_good_promote_timers
}

stop_stray_last_good_promote_timers() {
  for stale_pid in $(pgrep -f "magicctl promote-last-good" 2>/dev/null); do
    [ "$stale_pid" = "$$" ] && continue
    [ -r "/proc/$stale_pid/cmdline" ] || continue
    stale_cmdline="$(tr '\000' ' ' < "/proc/$stale_pid/cmdline" 2>/dev/null || true)"
    case "$stale_cmdline" in
      *"$DATA_DIR/magicctl"*"promote-last-good"*) kill -9 "$stale_pid" 2>/dev/null || true ;;
    esac
  done
}

watchdog_failure_count() {
  fails="$(cat "$FAIL_COUNT_FILE" 2>/dev/null)"
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  echo "$fails" > "$FAIL_COUNT_FILE"
  echo "$fails"
}

supervisor_start_child() {
  old_monitor_child="${SBMAGIC_MONITOR_CHILD:-}"
  SBMAGIC_MONITOR_CHILD=true
  start_service
  rc=$?
  SBMAGIC_MONITOR_CHILD="$old_monitor_child"
  SUPERVISOR_OWNED_PID="$(cat "$PID_FILE" 2>/dev/null)"
  return "$rc"
}

supervisor_rollback_child() {
  old_monitor_child="${SBMAGIC_MONITOR_CHILD:-}"
  SBMAGIC_MONITOR_CHILD=true
  rollback_service
  rc=$?
  SBMAGIC_MONITOR_CHILD="$old_monitor_child"
  SUPERVISOR_OWNED_PID="$(cat "$PID_FILE" 2>/dev/null)"
  return "$rc"
}

watchdog() {
  echo $$ > "$WATCHDOG_PID_FILE"
  SUPERVISOR_OWNED_PID=""
  WATCHDOG_OOM_APPLIED=false
  rm -f "$SUPERVISOR_RESTART_FILE" "$SUPERVISOR_ROLLBACK_FILE"
  log "watchdog supervisor started"
  while true; do
    load_settings
    if [ "$WATCHDOG_OOM_APPLIED" != "true" ]; then
      apply_oom_score_adj "$$" "watchdog"
      WATCHDOG_OOM_APPLIED=true
    fi
    if [ "$SBMAGIC_ENABLED" != "true" ]; then
      log "watchdog exiting: module disabled"
      rm -f "$WATCHDOG_PID_FILE"
      exit 0
    fi

    if ! pid_alive; then
      log "watchdog supervisor starting sing-box"
      if ! supervisor_start_child >/dev/null 2>>"$CONTROL_LOG"; then
        fails="$(watchdog_failure_count)"
        log "watchdog start failed (failure $fails/$FAIL_THRESHOLD)"
        if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
          sleep 3
          continue
        fi
        log "watchdog: $FAIL_THRESHOLD consecutive failures, trying last-good config"
        if [ -f "$LAST_GOOD_FILE" ] && supervisor_rollback_child >/dev/null 2>>"$CONTROL_LOG"; then
          echo 0 > "$FAIL_COUNT_FILE"
        else
          log "watchdog: last-good rollback also failed, disabling module to stop the crash loop"
          disable_service >/dev/null 2>&1
          echo 0 > "$FAIL_COUNT_FILE"
          rm -f "$WATCHDOG_PID_FILE"
          exit 0
        fi
      fi
    fi

    pid="$(cat "$PID_FILE" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*)
      sleep 1
      continue
      ;;
    esac
    if [ "$pid" != "$SUPERVISOR_OWNED_PID" ]; then
      log "watchdog found unmanaged sing-box pid=$pid; restarting under supervisor"
      stop_service_locked
      continue
    fi
    promote_last_good_later "$pid"
    wait "$pid" 2>/dev/null

    rm -f "$PID_FILE" "$PROCESS_FILE"
    remove_api_firewall

    if [ -f "$SUPERVISOR_ROLLBACK_FILE" ]; then
      rm -f "$SUPERVISOR_ROLLBACK_FILE"
      log "watchdog applying requested rollback"
      if supervisor_rollback_child >/dev/null 2>>"$CONTROL_LOG"; then
        echo 0 > "$FAIL_COUNT_FILE"
      else
        log "watchdog requested rollback failed"
        sleep 1
      fi
      continue
    fi

    if [ -f "$SUPERVISOR_RESTART_FILE" ]; then
      rm -f "$SUPERVISOR_RESTART_FILE"
      log "watchdog applying requested restart"
      echo 0 > "$FAIL_COUNT_FILE" 2>/dev/null
      continue
    fi

    load_settings_values
    if [ "$SBMAGIC_ENABLED" != "true" ]; then
      log "watchdog exiting after requested stop/disable"
      rm -f "$WATCHDOG_PID_FILE"
      exit 0
    fi

    fails="$(watchdog_failure_count)"
    log "watchdog detected child exit (failure $fails/$FAIL_THRESHOLD)"
    if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
      log "watchdog restarting sing-box with current config"
      continue
    fi

    log "watchdog: $FAIL_THRESHOLD consecutive failures, trying last-good config"
    if [ -f "$LAST_GOOD_FILE" ] && supervisor_rollback_child >/dev/null 2>>"$CONTROL_LOG"; then
      echo 0 > "$FAIL_COUNT_FILE"
      continue
    fi

    log "watchdog: last-good rollback also failed, disabling module to stop the crash loop"
    disable_service >/dev/null 2>&1
    echo 0 > "$FAIL_COUNT_FILE"
    rm -f "$WATCHDOG_PID_FILE"
    exit 0
  done
}

# Make sure exactly one watchdog loop is running when the service is enabled.
# Called after every successful (re)start instead of only at boot, so a
# watchdog that exited (disabled, or crash-loop shutdown) comes back the next
# time the user starts the service again.
ensure_watchdog() {
  [ "$SBMAGIC_WATCHDOG" = "true" ] || return 0
  if watchdog_alive; then
    return 0
  fi
  acquire_watchdog_lock || return 1
  if watchdog_alive; then
    release_watchdog_lock
    return 0
  fi
  rm -f "$WATCHDOG_PID_FILE"
  "$0" watchdog >/dev/null 2>&1 &
  release_watchdog_lock
}
