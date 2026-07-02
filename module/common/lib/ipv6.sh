# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

ipv6_state_value() {
  key="$1"
  fallback="$2"
  [ -f "$IPV6_STATE_FILE" ] || { echo "$fallback"; return 0; }
  value="$(sed -n "s/^$key=//p" "$IPV6_STATE_FILE" 2>/dev/null | tail -n 1)"
  [ -n "$value" ] || value="$fallback"
  echo "$value"
}

write_ipv6_state() {
  available="$1"
  effective_mode="$2"
  reason="$3"
  now="$(current_epoch)"
  tmp="$IPV6_STATE_FILE.tmp.$$"
  {
    echo "available=$available"
    echo "effective_mode=$effective_mode"
    echo "checked_at=$now"
    echo "reason=$reason"
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$IPV6_STATE_FILE" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$IPV6_STATE_FILE" 2>/dev/null || true
}

default_network_iface() {
  command -v ip >/dev/null 2>&1 || return 1
  line="$(ip route get 1.1.1.1 2>/dev/null | head -n 1)"
  set -- $line
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "dev" ]; then
      shift
      iface="${1%%@*}"
      [ -n "$iface" ] || return 1
      echo "$iface"
      return 0
    fi
    shift
  done
  return 1
}

ipv6_route_iface() {
  command -v ip >/dev/null 2>&1 || return 1
  line="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1)" || return 1
  set -- $line
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "dev" ]; then
      shift
      iface="${1%%@*}"
      [ -n "$iface" ] || return 1
      [ "$iface" = "$SBMAGIC_INTERFACE" ] && return 1
      [ "$iface" = "dummy0" ] && return 1
      [ "$iface" = "lo" ] && return 1
      echo "$iface"
      return 0
    fi
    shift
  done
  return 1
}

default_ipv6_iface() {
  if iface="$(ipv6_route_iface)"; then
    echo "$iface"
    return 0
  fi
  iface="$(default_network_iface)" || return 1
  ipv6_default_route_ok "$iface" || return 1
  echo "$iface"
}

ipv6_default_route_ok() {
  iface="$1"
  [ -n "$iface" ] || return 1
  command -v ip >/dev/null 2>&1 || return 1
  tmp="$RUNTIME_DIR/ipv6.route.$$"
  ip -6 route show table all > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  while IFS= read -r line; do
    set -- $line
    [ "$1" = "default" ] || continue
    dev=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "dev" ]; then
        shift
        dev="${1%%@*}"
        break
      fi
      shift
    done
    [ -n "$dev" ] || continue
    [ "$dev" = "$iface" ] || continue
    [ "$dev" = "$SBMAGIC_INTERFACE" ] && continue
    [ "$dev" = "dummy0" ] && continue
    [ "$dev" = "lo" ] && continue
    rm -f "$tmp"
    return 0
  done < "$tmp"
  rm -f "$tmp"
  return 1
}

ipv6_global_addr_ok() {
  iface="$1"
  [ -n "$iface" ] || return 1
  command -v ip >/dev/null 2>&1 || return 1
  tmp="$RUNTIME_DIR/ipv6.addr.$$"
  ip -6 -o addr show dev "$iface" scope global > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  while IFS= read -r line; do
    case "$line" in *" deprecated "*) continue ;; esac
    set -- $line
    [ "$3" = "inet6" ] || continue
    dev="${2%%@*}"
    addr="${4%%/*}"
    [ "$dev" = "$SBMAGIC_INTERFACE" ] && continue
    case "$addr" in
      2*|3*)
        rm -f "$tmp"
        return 0
        ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  return 1
}

ipv6_probe_ok() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -6 -L -sS \
    --resolve speed.cloudflare.com:443:2606:4700:4700::1111 \
    -o /dev/null \
    --connect-timeout 2 \
    --max-time 4 \
    "https://speed.cloudflare.com/__down?bytes=1" >/dev/null 2>&1
}

ipv6_network_available() {
  iface="$(default_ipv6_iface)" || return 1
  ipv6_global_addr_ok "$iface" || return 1
  ipv6_probe_ok || return 1
}

detect_ipv6_effective_mode() {
  iface="$(default_ipv6_iface)" || { echo off; return 0; }
  if ! ipv6_global_addr_ok "$iface"; then
    echo off
    return 0
  fi
  if ipv6_probe_ok; then
    echo proxy
  else
    echo block
  fi
}

configured_ipv6_mode() {
  case "$SBMAGIC_IPV6_MODE" in
    "") echo block ;;
    *) echo "$SBMAGIC_IPV6_MODE" ;;
  esac
}

effective_ipv6_mode() {
  ipv6_configured_mode="$(configured_ipv6_mode)"
  if [ "$ipv6_configured_mode" = "auto" ]; then
    ipv6_state_mode="$(ipv6_state_value effective_mode "")"
    case "$ipv6_state_mode" in
      proxy|block|off) echo "$ipv6_state_mode"; return 0 ;;
    esac
  fi
  echo "$ipv6_configured_mode"
}

refresh_ipv6_runtime_state() {
  ipv6_reason="$1"
  ipv6_configured_mode="$(configured_ipv6_mode)"
  ipv6_old_available="$(ipv6_state_value available unknown)"
  ipv6_old_mode="$(ipv6_state_value effective_mode unknown)"

  if [ "$ipv6_configured_mode" != "auto" ]; then
    write_ipv6_state disabled "$ipv6_configured_mode" "$ipv6_reason" || return 1
    [ "$ipv6_old_available" = "disabled" ] && [ "$ipv6_old_mode" = "$ipv6_configured_mode" ] && return 0
    return 2
  fi

  ipv6_detected_mode="$(detect_ipv6_effective_mode)"
  if [ "$ipv6_detected_mode" = "proxy" ]; then
    ipv6_available=true
  else
    ipv6_available=false
  fi
  write_ipv6_state "$ipv6_available" "$ipv6_detected_mode" "$ipv6_reason" || return 1
  [ "$ipv6_old_available" = "$ipv6_available" ] && [ "$ipv6_old_mode" = "$ipv6_detected_mode" ] && return 0
  log "IPv6 auto fallback state changed: available=$ipv6_available effective=$ipv6_detected_mode reason=$ipv6_reason"
  return 2
}
