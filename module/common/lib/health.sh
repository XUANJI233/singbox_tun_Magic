# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

tun_health_text() {
  command -v ip >/dev/null 2>&1 || { echo unknown; return 0; }
  if ip link show "$SBMAGIC_INTERFACE" >/dev/null 2>&1; then
    echo true
  else
    echo false
  fi
}

tun_health_ok_or_unknown() {
  state="$(tun_health_text)"
  [ "$state" != "false" ]
}

runtime_ready() {
  pid_alive || return 1
  api_health_ok || return 1
  [ "$(tun_health_text)" = "true" ] || return 1
}

service_ready_after_start() {
  runtime_ready || return 1
  [ "$SBMAGIC_NETWORK_WATCH" != "true" ] || netwatch_alive
}

wait_for_runtime_ready() {
  i=0
  while [ "$i" -lt 15 ]; do
    pid_alive || return 1
    runtime_ready && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

flush_runtime_connections() {
  [ "$SBMAGIC_NETWORK_CHANGE_FLUSH" = "true" ] || return 0
  ensure_api_env
  api_call_once DELETE /connections "" >/dev/null 2>&1 || true
}

recover_if_unhealthy() {
  reason="$1"
  load_settings
  if [ "$SBMAGIC_ENABLED" != "true" ]; then
    echo "enabled=false"
    return 0
  fi
  if ! pid_alive; then
    log "recover($reason): core not running; starting service"
    start_service
    return $?
  fi
  if api_health_ok_after_retries "$SBMAGIC_NETWORK_HEALTH_RETRIES" "$SBMAGIC_NETWORK_HEALTH_RETRY_DELAY"; then
    if ! tun_health_ok_or_unknown; then
      log "recover($reason): API healthy but tun missing; restarting service"
      restart_service
      return $?
    fi
    if [ "$SBMAGIC_NETWORK_CHANGE_FLUSH" = "true" ]; then
      log "recover($reason): API healthy; closing stale runtime connections"
      flush_runtime_connections
      echo "recovered=flushed-connections"
    else
      log "recover($reason): API healthy; no connection flush configured"
      echo "recovered=api-healthy"
    fi
    return 0
  fi
  log "recover($reason): API unresponsive after retries while pid is alive; restarting service"
  restart_service
}

recover_service() {
  recover_if_unhealthy "manual"
}
