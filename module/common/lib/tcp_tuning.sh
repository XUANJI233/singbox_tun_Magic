# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

tcp_congestion_control_sysctl() {
  echo /proc/sys/net/ipv4/tcp_congestion_control
}

tcp_congestion_control_original_file() {
  echo "$RUNTIME_DIR/tcp_congestion_control.original"
}

tcp_congestion_control_available() {
  cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

tcp_congestion_control_current() {
  cat "$(tcp_congestion_control_sysctl)" 2>/dev/null
}

save_tcp_congestion_control_original() {
  original_file="$(tcp_congestion_control_original_file)"
  [ -s "$original_file" ] && return 0
  current="$(tcp_congestion_control_current)"
  [ -n "$current" ] || return 0
  mkdirs
  printf '%s\n' "$current" > "$original_file" 2>/dev/null || true
}

restore_tcp_congestion_control() {
  original_file="$(tcp_congestion_control_original_file)"
  [ -s "$original_file" ] || return 0
  original="$(cat "$original_file" 2>/dev/null)"
  [ -n "$original" ] || { rm -f "$original_file"; return 0; }
  sysctl_path="$(tcp_congestion_control_sysctl)"
  [ -w "$sysctl_path" ] || return 0
  if echo "$original" > "$sysctl_path" 2>/dev/null; then
    log "tcp congestion control restored: $original"
    rm -f "$original_file"
  fi
}

apply_tcp_congestion_control() {
  cc="${SBMAGIC_TCP_CONGESTION_CONTROL:-system}"
  if [ "$cc" = "system" ]; then
    restore_tcp_congestion_control
    return 0
  fi

  sysctl_path="$(tcp_congestion_control_sysctl)"
  if [ ! -w "$sysctl_path" ]; then
    log "tcp congestion control skipped: sysctl unavailable"
    return 0
  fi

  available="$(tcp_congestion_control_available)"
  case " $available " in
    *" $cc "*) ;;
    *)
      log "tcp congestion control skipped: $cc unavailable ($available)"
      return 0
      ;;
  esac

  current="$(tcp_congestion_control_current)"
  [ "$current" = "$cc" ] && { log "tcp congestion control active: $cc"; return 0; }
  save_tcp_congestion_control_original
  if echo "$cc" > "$sysctl_path" 2>/dev/null; then
    log "tcp congestion control active: $cc"
  else
    log "tcp congestion control skipped: failed to set $cc"
  fi
}
