# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

iptables_run() {
  bin="$1"
  shift
  "$bin" -w "$@" 2>/dev/null || "$bin" "$@" 2>/dev/null
}

remove_api_firewall() {
  command -v iptables >/dev/null 2>&1 || return 0
  while iptables_run iptables -D OUTPUT -j SBMAGIC_API; do :; done
  iptables_run iptables -F SBMAGIC_API || true
  iptables_run iptables -X SBMAGIC_API || true
}

apply_api_firewall() {
  if [ "$(json_bool "$SBMAGIC_API_FIREWALL")" != "true" ]; then
    remove_api_firewall
    return 0
  fi
  [ "$SBMAGIC_API_HOST" = "127.0.0.1" ] || { log "api firewall skipped: non-loopback host $SBMAGIC_API_HOST"; return 0; }
  valid_port "$SBMAGIC_API_PORT" || { log "api firewall skipped: invalid port $SBMAGIC_API_PORT"; return 0; }
  command -v iptables >/dev/null 2>&1 || { log "api firewall skipped: iptables unavailable"; return 0; }

  remove_api_firewall
  iptables_run iptables -N SBMAGIC_API || { log "api firewall skipped: cannot create chain"; return 0; }
  if ! iptables_run iptables -A SBMAGIC_API -p tcp -d 127.0.0.1 --dport "$SBMAGIC_API_PORT" -m owner --uid-owner 0 -j RETURN; then
    log "api firewall skipped: owner match unavailable"
    remove_api_firewall
    return 0
  fi
  iptables_run iptables -A SBMAGIC_API -p tcp -d 127.0.0.1 --dport "$SBMAGIC_API_PORT" -m owner --uid-owner 2000 -j RETURN || true
  iptables_run iptables -A SBMAGIC_API -p tcp -d 127.0.0.1 --dport "$SBMAGIC_API_PORT" -j REJECT || {
    log "api firewall skipped: reject rule failed"
    remove_api_firewall
    return 0
  }
  iptables_run iptables -I OUTPUT 1 -j SBMAGIC_API || {
    log "api firewall skipped: cannot attach chain"
    remove_api_firewall
    return 0
  }
  log "api firewall active on 127.0.0.1:$SBMAGIC_API_PORT"
}
