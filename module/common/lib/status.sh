# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

file_mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || echo 0
}

file_mtime_text() {
  stat -c '%y' "$1" 2>/dev/null | cut -d'.' -f1
}

ruleset_cache_time() {
  newest_file=""
  newest_epoch=0
  for candidate in "$GEOSITE_CN_RULESET" "$GEOIP_CN_RULESET"; do
    [ -f "$candidate" ] || continue
    epoch="$(file_mtime_epoch "$candidate")"
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    if [ "$epoch" -gt "$newest_epoch" ]; then
      newest_epoch="$epoch"
      newest_file="$candidate"
    fi
  done
  if [ -n "$newest_file" ]; then
    file_mtime_text "$newest_file"
    return 0
  fi

  for candidate in "$CACHE_DIR"/cache.db "$CACHE_DIR"/cache.db-* "$CACHE_DIR"/*.srs "$CACHE_DIR"/rule*; do
    [ -f "$candidate" ] || continue
    epoch="$(file_mtime_epoch "$candidate")"
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    if [ "$epoch" -gt "$newest_epoch" ]; then
      newest_epoch="$epoch"
      newest_file="$candidate"
    fi
  done
  if [ -n "$newest_file" ]; then
    file_mtime_text "$newest_file"
  else
    echo "none"
  fi
}

status() {
  mkdirs
  status_config_error=""
  if ( load_settings ) >/dev/null 2>"$RUNTIME_DIR/status-settings.err"; then
    load_settings
  else
    status_config_error="$(cat "$RUNTIME_DIR/status-settings.err" 2>/dev/null)"
    load_settings_values
    set_process_binary_path_relaxed >/dev/null 2>&1 || true
  fi
  configured_port="$SBMAGIC_API_PORT"
  if [ -f "$API_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$API_ENV_FILE" 2>/dev/null || true
  fi
  case "$configured_port" in
    auto|AUTO|"") ;;
    *)
      if valid_port "$configured_port"; then
        SBMAGIC_API_PORT="$configured_port"
      fi
      ;;
  esac
  echo "enabled=$SBMAGIC_ENABLED"
  echo "settings_version=$SBMAGIC_SETTINGS_VERSION"
  if [ -n "$status_config_error" ]; then
    echo "config_valid=false"
    echo "config_error=$status_config_error"
  else
    echo "config_valid=true"
  fi
  if pid_alive; then
    echo "running=true"
    echo "pid=$(cat "$PID_FILE")"
    if api_health_ok; then
      echo "api_alive=true"
    else
      echo "api_alive=false"
    fi
    echo "tun_alive=$(tun_health_text)"
  else
    echo "running=false"
    echo "api_alive=false"
    echo "tun_alive=false"
  fi
  echo "data_dir=$DATA_DIR"
  echo "config=$CONFIG_FILE"
  echo "process_name=$SBMAGIC_PROCESS_NAME"
  echo "tun_interface=$SBMAGIC_INTERFACE"
  echo "api=http://$SBMAGIC_API_HOST:$SBMAGIC_API_PORT"
  echo "mode=$SBMAGIC_API_MODE"
  echo "boot_start=$SBMAGIC_BOOT_START"
  echo "init_service=$SBMAGIC_INIT_SERVICE"
  if [ -f "$INITD_SEEN_FILE" ]; then
    echo "init_service_seen=$(cat "$INITD_SEEN_FILE" 2>/dev/null)"
  else
    echo "init_service_seen=none"
  fi
  echo "watchdog=$SBMAGIC_WATCHDOG"
  if watchdog_alive; then
    echo "watchdog_running=true"
    echo "watchdog_mode=supervisor"
  else
    echo "watchdog_running=false"
  fi
  echo "network_watch=$SBMAGIC_NETWORK_WATCH"
  echo "network_change_flush=$SBMAGIC_NETWORK_CHANGE_FLUSH"
  echo "network_recovery_cooldown=$SBMAGIC_NETWORK_RECOVERY_COOLDOWN"
  echo "network_settle_delay=$SBMAGIC_NETWORK_SETTLE_DELAY"
  echo "network_health_retries=$SBMAGIC_NETWORK_HEALTH_RETRIES"
  echo "network_health_retry_delay=$SBMAGIC_NETWORK_HEALTH_RETRY_DELAY"
  echo "network_own_tun_grace=$SBMAGIC_NETWORK_OWN_TUN_GRACE"
  if netwatch_alive; then
    echo "network_watch_running=true"
  else
    echo "network_watch_running=false"
  fi
  echo "oom_protect=$SBMAGIC_OOM_PROTECT"
  echo "oom_score_adj=$SBMAGIC_OOM_SCORE_ADJ"
  if pid_alive; then
    echo "current_oom_score_adj=$(cat "/proc/$(cat "$PID_FILE")/oom_score_adj" 2>/dev/null || echo unknown)"
  fi
  echo "package_mode=$SBMAGIC_PACKAGE_MODE"
  echo "tun_stack=$SBMAGIC_STACK"
  echo "package_database_readable=$(package_database_readable_text)"
  echo "proxy_rule_mode=$SBMAGIC_PROXY_RULE_MODE"
  echo "free_flow_rule_mode=$SBMAGIC_FREE_FLOW_RULE_MODE"
  echo "mixed_rule_priority=$SBMAGIC_MIXED_RULE_PRIORITY"
  proxy_strategy_count="$(package_file_entry_count "$PROXY_PACKAGES_FILE")"
  free_flow_strategy_count="$(package_file_entry_count "$FREE_FLOW_PACKAGES_FILE")"
  strategy_package_count=$((proxy_strategy_count + free_flow_strategy_count))
  proxy_lookup_count="$proxy_strategy_count"
  free_flow_lookup_count="$free_flow_strategy_count"
  [ "$SBMAGIC_MIXED_RULE_PRIORITY" = "proxy" ] && proxy_lookup_count=0
  [ "$SBMAGIC_MIXED_RULE_PRIORITY" = "free-flow" ] && free_flow_lookup_count=0
  strategy_process_lookup=false
  if [ "$proxy_lookup_count" -gt 0 ] && [ "$SBMAGIC_PROXY_RULE_MODE" != "off" ]; then
    strategy_process_lookup=true
  fi
  if [ "$free_flow_lookup_count" -gt 0 ] && [ "$SBMAGIC_FREE_FLOW_RULE_MODE" != "off" ]; then
    strategy_process_lookup=true
  fi
  echo "strategy_package_count=$strategy_package_count"
  echo "strategy_process_lookup=$strategy_process_lookup"
  echo "ruleset_download_detour=$SBMAGIC_RULESET_DOWNLOAD_DETOUR"
  if rule_sets_used; then
    echo "ruleset_active=true"
  else
    echo "ruleset_active=false"
  fi
  echo "ruleset_update_interval=$SBMAGIC_RULE_UPDATE_INTERVAL"
  echo "ruleset_cache_time=$(ruleset_cache_time)"
  echo "sniff=$SBMAGIC_SNIFF"
  echo "sniff_timeout=$SBMAGIC_SNIFF_TIMEOUT"
  echo "auto_redirect=$SBMAGIC_AUTO_REDIRECT"
  echo "tcp_congestion_control=$SBMAGIC_TCP_CONGESTION_CONTROL"
  if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    echo "tcp_congestion_control_current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)"
  fi
  echo "udp_native_mode=$SBMAGIC_UDP_NATIVE_MODE"
  echo "udp_native_outbound=$SBMAGIC_UDP_NATIVE_OUTBOUND"
  echo "endpoint_independent_nat=$SBMAGIC_ENDPOINT_INDEPENDENT_NAT"
  echo "reject_quic=$SBMAGIC_REJECT_QUIC"
  echo "udp_timeout=$SBMAGIC_UDP_TIMEOUT"
  echo "udp_timeout_effective=$(effective_udp_timeout)"
  echo "dns_mode=$SBMAGIC_DNS_MODE"
  echo "dns_reverse_mapping=$SBMAGIC_DNS_REVERSE_MAPPING"
  echo "ipv6=$SBMAGIC_IPV6"
  echo "ipv6_mode=$SBMAGIC_IPV6_MODE"
  echo "ipv6_available=$(ipv6_state_value available unknown)"
  echo "ipv6_effective_mode=$(effective_ipv6_mode)"
  if [ -f "$LAST_GOOD_FILE" ]; then
    echo "last_good=$(stat -c '%y' "$LAST_GOOD_FILE" 2>/dev/null | cut -d'.' -f1)"
  else
    echo "last_good=none"
  fi
  echo "fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)"
  core_version
}

logs() {
  target="$1"
  lines="$2"
  [ -n "$lines" ] || lines=120
  case "$target" in
    box) file="$LOG_DIR/box.log" ;;
    control) file="$CONTROL_LOG" ;;
    *) file="$RUN_LOG" ;;
  esac
  tail -n "$lines" "$file" 2>/dev/null || true
}
