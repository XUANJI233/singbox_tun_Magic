# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

render_config() {
  mkdirs
  load_settings
  prepare_process_binary
  ensure_api_env

  [ -x "$SING_BOX" ] || die "sing-box binary missing: $SING_BOX"
  [ -x "$RENDERER" ] || die "magicctl-go missing: $RENDERER"
  [ -f "$OUTBOUNDS_FILE" ] || die "outbounds file missing: $OUTBOUNDS_FILE"
  ensure_no_strategy_conflicts
  refresh_ipv6_runtime_state "render"
  ipv6_rc=$?
  [ "$ipv6_rc" -eq 0 ] || [ "$ipv6_rc" -eq 2 ] || die "IPv6 state check failed"

  "$RENDERER" render --data-dir "$DATA_DIR" --output "$CONFIG_FILE"
}

check_config() {
  render_config >/dev/null || return 1
  validate_runtime_ready || return 1
  "$SING_BOX" check -D "$DATA_DIR" -c "$CONFIG_FILE"
}

config_precheck_signature() {
  config_fp="$(file_fingerprint "$CONFIG_FILE")"
  core_fp="$(file_fingerprint "$CORE_BIN")"
  [ -n "$config_fp" ] && [ -n "$core_fp" ] || return 1
  {
    echo "config=$config_fp"
    echo "core=$core_fp"
  }
}

mark_prechecked_config() {
  tmp="$PRECHECKED_CONFIG_FILE.$$"
  config_precheck_signature > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$PRECHECKED_CONFIG_FILE"
  chmod 600 "$PRECHECKED_CONFIG_FILE" 2>/dev/null
}

consume_prechecked_config() {
  [ -f "$PRECHECKED_CONFIG_FILE" ] || return 1
  expected="$(cat "$PRECHECKED_CONFIG_FILE" 2>/dev/null)"
  rm -f "$PRECHECKED_CONFIG_FILE"
  current="$(config_precheck_signature 2>/dev/null)" || return 1
  [ "$expected" = "$current" ]
}

validate_runtime_ready() {
  ensure_no_strategy_conflicts
  validate_package_database_access

  need_proxy=false
  need_free_flow=false

  if package_file_has_entries "$PROXY_PACKAGES_FILE" && [ "$SBMAGIC_PROXY_RULE_MODE" = "off" ]; then
    die "packages.proxy is not empty but SBMAGIC_PROXY_RULE_MODE=off"
  fi
  if package_file_has_entries "$FREE_FLOW_PACKAGES_FILE" && [ "$SBMAGIC_FREE_FLOW_RULE_MODE" = "off" ]; then
    die "packages.free-flow is not empty but SBMAGIC_FREE_FLOW_RULE_MODE=off"
  fi

  [ "$SBMAGIC_PROXY_RULE_MODE" != "off" ] && need_proxy=true
  [ "$SBMAGIC_API_MODE" = "Global" ] && need_proxy=true
  [ "$SBMAGIC_FREE_FLOW_RULE_MODE" != "off" ] && need_free_flow=true

  if [ "$need_proxy" != "true" ] && [ "$need_free_flow" != "true" ]; then
    die "no proxy/free-flow rule is enabled; refusing to start an all-direct service"
  fi

  [ -x "$FETCHER" ] || die "magic-fetch missing: $FETCHER"
  args=""
  $need_proxy && args="$args --need-proxy"
  $need_free_flow && args="$args --need-free-flow"
  # shellcheck disable=SC2086
  "$FETCHER" --validate-outbounds "$OUTBOUNDS_FILE" $args || die "outbounds are not ready for selected routing modes"
}

check_config_scratch() {
  old_config_file="$CONFIG_FILE"
  CONFIG_FILE="$RUNTIME_DIR/config.check.$$"
  rm -f "$CONFIG_FILE" "$CONFIG_FILE.tmp.$$"
  render_config >/dev/null || {
    rc=$?
    rm -f "$CONFIG_FILE" "$CONFIG_FILE.tmp.$$"
    CONFIG_FILE="$old_config_file"
    return "$rc"
  }
  "$SING_BOX" check -D "$DATA_DIR" -c "$CONFIG_FILE"
  rc=$?
  rm -f "$CONFIG_FILE" "$CONFIG_FILE.tmp.$$"
  CONFIG_FILE="$old_config_file"
  return "$rc"
}
