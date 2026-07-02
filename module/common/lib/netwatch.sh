# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

network_event_is_own_tun() {
  event="$1"
  [ -n "$SBMAGIC_INTERFACE" ] || return 1
  case "$event" in
    *"$SBMAGIC_INTERFACE"*) return 0 ;;
    *) return 1 ;;
  esac
}

netwatch_event_iface() {
  event="$1"
  set -- $event
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [0-9]*:)
        [ "$#" -gt 1 ] || return 1
        iface="${2%%@*}"
        iface="${iface%:}"
        [ -n "$iface" ] && echo "$iface"
        return 0
        ;;
      dev)
        [ "$#" -gt 1 ] || return 1
        iface="${2%%@*}"
        iface="${iface%:}"
        [ -n "$iface" ] && echo "$iface"
        return 0
        ;;
    esac
    shift
  done
  return 1
}

netwatch_event_is_default_route() {
  case "$1" in
    default*|Deleted\ default*|*" default "*) return 0 ;;
    *) return 1 ;;
  esac
}

netwatch_iface_is_noise() {
  case "$1" in
    p2p*|dummy*|ifb*|lo|sit*|ip6tnl*|rmnet_ipa*) return 0 ;;
    *) return 1 ;;
  esac
}

netwatch_event_is_noise_iface() {
  event="$1"
  netwatch_event_is_default_route "$event" && return 1
  iface="$(netwatch_event_iface "$event")" || return 1
  [ "$iface" = "$SBMAGIC_INTERFACE" ] && return 1
  netwatch_iface_is_noise "$iface"
}

network_own_tun_grace_seconds() {
  value="${SBMAGIC_NETWORK_OWN_TUN_GRACE:-$NETWATCH_OWN_TUN_GRACE_SECONDS}"
  case "$value" in ''|*[!0-9]*) value="$NETWATCH_OWN_TUN_GRACE_SECONDS" ;; esac
  echo "$value"
}

mark_netwatch_own_tun_grace() {
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
  now="$(current_epoch)"
  [ "$now" -gt 0 ] || return 0
  echo $((now + $(network_own_tun_grace_seconds))) > "$NETWATCH_IGNORE_UNTIL_FILE"
  rm -f "$NETWATCH_IGNORE_LOGGED_FILE"
  chmod 600 "$NETWATCH_IGNORE_UNTIL_FILE" 2>/dev/null || true
}

netwatch_own_tun_grace_active() {
  [ -f "$NETWATCH_IGNORE_UNTIL_FILE" ] || return 1
  until_epoch="$(cat "$NETWATCH_IGNORE_UNTIL_FILE" 2>/dev/null)"
  case "$until_epoch" in
    ''|*[!0-9]*)
      rm -f "$NETWATCH_IGNORE_UNTIL_FILE" "$NETWATCH_IGNORE_LOGGED_FILE"
      return 1
      ;;
  esac
  now="$(current_epoch)"
  if [ "$now" -gt 0 ] && [ "$now" -le "$until_epoch" ]; then
    return 0
  fi
  rm -f "$NETWATCH_IGNORE_UNTIL_FILE" "$NETWATCH_IGNORE_LOGGED_FILE"
  return 1
}

log_netwatch_own_tun_grace_once() {
  [ -f "$NETWATCH_IGNORE_LOGGED_FILE" ] && return 0
  log "network watch ignored own tun events during core restart"
  : > "$NETWATCH_IGNORE_LOGGED_FILE"
  chmod 600 "$NETWATCH_IGNORE_LOGGED_FILE" 2>/dev/null || true
}

snapshot_netwatch_ipv6_addrs() {
  tmp="$NETWATCH_IPV6_ADDR_STATE_FILE.tmp.$$"
  ip -6 -o addr show scope global 2>/dev/null | while IFS= read -r line; do
    set -- $line
    [ "$3" = "inet6" ] || continue
    iface="${2%%@*}"
    printf '%s %s\n' "$iface" "$4"
  done | sort > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$NETWATCH_IPV6_ADDR_STATE_FILE" 2>/dev/null || rm -f "$tmp"
}

netwatch_event_is_known_ipv6_addr_refresh() {
  event="$1"
  case "$event" in
    *" inet6 "*) ;;
    *) return 1 ;;
  esac
  set -- $event
  [ "$1" = "Deleted" ] && return 1
  iface="${2%%@*}"
  family="$3"
  address="$4"
  [ "$family" = "inet6" ] || return 1
  [ -n "$iface" ] && [ -n "$address" ] || return 1
  [ -f "$NETWATCH_IPV6_ADDR_STATE_FILE" ] || return 1
  grep -Fqx "$iface $address" "$NETWATCH_IPV6_ADDR_STATE_FILE" 2>/dev/null
}

netwatch_event_is_ipv6_lifetime_line() {
  case "$1" in
    *"valid_lft "*"preferred_lft"*) return 0 ;;
    *) return 1 ;;
  esac
}

netwatch_event_updates_ipv6_addr_state() {
  case "$1" in
    *" inet6 "*) snapshot_netwatch_ipv6_addrs >/dev/null 2>&1 || true ;;
  esac
}

netwatch() {
  echo $$ > "$NETWATCH_PID_FILE"
  NETWATCH_FIFO="$RUNTIME_DIR/netwatch.events.$$"
  trap 'netwatch_cleanup' EXIT INT TERM HUP
  log "network watch started"
  if ! command -v ip >/dev/null 2>&1; then
    log "network watch exiting: ip command unavailable"
    exit 0
  fi
  if ! command -v mkfifo >/dev/null 2>&1; then
    log "network watch exiting: mkfifo command unavailable"
    exit 0
  fi

  cleanup_netwatch_fifos
  snapshot_netwatch_ipv6_addrs >/dev/null 2>&1 || true
  last_event=0
  while true; do
    rm -f "$NETWATCH_FIFO"
    if ! mkfifo "$NETWATCH_FIFO"; then
      log "network watch monitor fifo failed; retrying"
      sleep 10
      continue
    fi
    ip monitor route address link > "$NETWATCH_FIFO" 2>>"$CONTROL_LOG" &
    echo $! > "$NETWATCH_MONITOR_PID_FILE"
    while IFS= read -r event; do
      [ -n "$event" ] || continue
      if ! load_settings >/dev/null 2>>"$CONTROL_LOG"; then
        log "network watch ignored event because settings are invalid"
        continue
      fi
      if [ "$SBMAGIC_ENABLED" != "true" ] || [ "$SBMAGIC_NETWORK_WATCH" != "true" ]; then
        log "network watch exiting: disabled"
        rm -f "$NETWATCH_PID_FILE"
        exit 0
      fi
      if netwatch_own_tun_grace_active; then
        log_netwatch_own_tun_grace_once
        continue
      fi
      if netwatch_event_is_ipv6_lifetime_line "$event"; then
        continue
      fi
      if netwatch_event_is_known_ipv6_addr_refresh "$event"; then
        continue
      fi
      if netwatch_event_is_noise_iface "$event"; then
        continue
      fi
      own_tun_event=false
      if network_event_is_own_tun "$event"; then
        if tun_health_ok_or_unknown; then
          continue
        fi
        own_tun_event=true
        log "network watch tun missing after event: $event"
      fi
      netwatch_event_updates_ipv6_addr_state "$event"
      now="$(date +%s 2>/dev/null || echo 0)"
      case "$now" in ''|*[!0-9]*) now=0 ;; esac
      cooldown="$SBMAGIC_NETWORK_RECOVERY_COOLDOWN"
      case "$cooldown" in ''|*[!0-9]*) cooldown=30 ;; esac
      if [ "$own_tun_event" != "true" ] && [ "$last_event" -ne 0 ] && [ $((now - last_event)) -lt "$cooldown" ]; then
        continue
      fi
      last_event="$now"
      log "network watch event: $event"
      settle="$SBMAGIC_NETWORK_SETTLE_DELAY"
      case "$settle" in ''|*[!0-9]*) settle=2 ;; esac
      [ "$settle" -gt 0 ] && sleep "$settle"
      refresh_ipv6_runtime_state "network-change"
      ipv6_rc=$?
      if [ "$ipv6_rc" -eq 2 ] && pid_alive; then
        log "network watch restarting service after IPv6 state change"
        restart_service >/dev/null 2>>"$CONTROL_LOG" || true
        continue
      fi
      recover_if_unhealthy "network-change" >/dev/null 2>>"$CONTROL_LOG" || true
    done < "$NETWATCH_FIFO"
    stop_netwatch_monitor
    rm -f "$NETWATCH_FIFO"
    if ! load_settings >/dev/null 2>>"$CONTROL_LOG"; then
      log "network watch paused: settings invalid"
    elif [ "$SBMAGIC_ENABLED" != "true" ] || [ "$SBMAGIC_NETWORK_WATCH" != "true" ]; then
      log "network watch exiting: disabled"
      rm -f "$NETWATCH_PID_FILE"
      exit 0
    fi
    log "network watch monitor exited; retrying"
    sleep 10
  done
}

netwatch_cleanup() {
  stop_netwatch_monitor
  rm -f "$NETWATCH_FIFO"
  if [ "$(cat "$NETWATCH_PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$NETWATCH_PID_FILE"
  fi
}
