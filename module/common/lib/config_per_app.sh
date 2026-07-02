# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

config_set_strategy_packages() {
  marker="__SBMAGIC_FREE_FLOW_PACKAGES__"
  acquire_config_lock || die "another config operation is already in progress"
  tmp_proxy=""
  tmp_free_flow=""
  old_proxy_packages_file=""
  old_free_flow_packages_file=""
  trap '[ -n "$tmp_proxy" ] && rm -f "$tmp_proxy"; [ -n "$tmp_free_flow" ] && rm -f "$tmp_free_flow"; release_config_lock' EXIT INT TERM HUP
  mkdirs
  tmp_proxy="$PROXY_PACKAGES_FILE.tmp.$$"
  tmp_free_flow="$FREE_FLOW_PACKAGES_FILE.tmp.$$"
  : > "$tmp_proxy"
  : > "$tmp_free_flow"
  awk -v marker="$marker" -v proxy="$tmp_proxy" -v free_flow="$tmp_free_flow" '
    BEGIN { out = proxy }
    $0 == marker { out = free_flow; seen_marker = 1; next }
    { print > out }
    END { if (!seen_marker) exit 2 }
  ' || { rm -f "$tmp_proxy" "$tmp_free_flow"; die "strategy package payload missing marker"; }

  ensure_no_strategy_conflicts_files "$tmp_proxy" "$tmp_free_flow"

  old_proxy_packages_file="$PROXY_PACKAGES_FILE"
  old_free_flow_packages_file="$FREE_FLOW_PACKAGES_FILE"
  PROXY_PACKAGES_FILE="$tmp_proxy"
  FREE_FLOW_PACKAGES_FILE="$tmp_free_flow"
  if ! ( check_config_scratch ) >/dev/null 2>&1; then
    PROXY_PACKAGES_FILE="$old_proxy_packages_file"
    FREE_FLOW_PACKAGES_FILE="$old_free_flow_packages_file"
    rm -f "$tmp_proxy" "$tmp_free_flow"
    die "rendered config check failed for strategy packages; kept previous files"
  fi
  PROXY_PACKAGES_FILE="$old_proxy_packages_file"
  FREE_FLOW_PACKAGES_FILE="$old_free_flow_packages_file"

  cp -f "$PROXY_PACKAGES_FILE" "$PROXY_PACKAGES_FILE.bak" 2>/dev/null
  cp -f "$FREE_FLOW_PACKAGES_FILE" "$FREE_FLOW_PACKAGES_FILE.bak" 2>/dev/null
  mv -f "$tmp_proxy" "$PROXY_PACKAGES_FILE"
  mv -f "$tmp_free_flow" "$FREE_FLOW_PACKAGES_FILE"
  chmod 600 "$PROXY_PACKAGES_FILE" "$FREE_FLOW_PACKAGES_FILE"
  log "config set strategy packages"
  trap - EXIT INT TERM HUP
  release_config_lock
  echo "ok"
}

settings_with_value() {
  src="$1"
  dest="$2"
  key="$3"
  value="$4"
  if [ -f "$src" ]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { seen = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        seen = 1
        next
      }
      { print }
      END {
        if (!seen) print key "=" value
      }
    ' "$src" > "$dest"
  else
    echo "$key=$value" > "$dest"
  fi
}

config_set_per_app() {
  marker_mode="__SBMAGIC_PACKAGE_MODE__"
  marker_exclude="__SBMAGIC_EXCLUDE_PACKAGES__"
  marker_include="__SBMAGIC_INCLUDE_PACKAGES__"
  marker_proxy="__SBMAGIC_PROXY_PACKAGES__"
  marker_free_flow="__SBMAGIC_FREE_FLOW_PACKAGES__"
  acquire_config_lock || die "another config operation is already in progress"
  tmp_mode=""
  tmp_settings=""
  tmp_exclude=""
  tmp_include=""
  tmp_proxy=""
  tmp_free_flow=""
  old_settings_file=""
  old_exclude_file=""
  old_include_file=""
  old_proxy_packages_file=""
  old_free_flow_packages_file=""
  trap '[ -n "$tmp_mode" ] && rm -f "$tmp_mode"; [ -n "$tmp_settings" ] && rm -f "$tmp_settings"; [ -n "$tmp_exclude" ] && rm -f "$tmp_exclude"; [ -n "$tmp_include" ] && rm -f "$tmp_include"; [ -n "$tmp_proxy" ] && rm -f "$tmp_proxy"; [ -n "$tmp_free_flow" ] && rm -f "$tmp_free_flow"; release_config_lock' EXIT INT TERM HUP
  mkdirs
  tmp_mode="$RUNTIME_DIR/package-mode.$$"
  tmp_settings="$SETTINGS_FILE.tmp.$$"
  tmp_exclude="$EXCLUDE_FILE.tmp.$$"
  tmp_include="$INCLUDE_FILE.tmp.$$"
  tmp_proxy="$PROXY_PACKAGES_FILE.tmp.$$"
  tmp_free_flow="$FREE_FLOW_PACKAGES_FILE.tmp.$$"
  : > "$tmp_mode"
  : > "$tmp_exclude"
  : > "$tmp_include"
  : > "$tmp_proxy"
  : > "$tmp_free_flow"
  awk \
    -v marker_mode="$marker_mode" -v marker_exclude="$marker_exclude" \
    -v marker_include="$marker_include" -v marker_proxy="$marker_proxy" \
    -v marker_free_flow="$marker_free_flow" \
    -v mode="$tmp_mode" -v exclude="$tmp_exclude" -v include="$tmp_include" \
    -v proxy="$tmp_proxy" -v free_flow="$tmp_free_flow" '
      $0 == marker_mode { out = mode; seen_mode = 1; next }
      $0 == marker_exclude { out = exclude; seen_exclude = 1; next }
      $0 == marker_include { out = include; seen_include = 1; next }
      $0 == marker_proxy { out = proxy; seen_proxy = 1; next }
      $0 == marker_free_flow { out = free_flow; seen_free_flow = 1; next }
      out != "" { print > out }
      END {
        if (!seen_mode || !seen_exclude || !seen_include || !seen_proxy || !seen_free_flow) exit 2
      }
    ' || {
      rm -f "$tmp_mode" "$tmp_settings" "$tmp_exclude" "$tmp_include" "$tmp_proxy" "$tmp_free_flow"
      die "per-app payload missing marker"
    }

  package_mode="$(tr -d '[:space:]' < "$tmp_mode" 2>/dev/null)"
  validate_one_of "$package_mode" SBMAGIC_PACKAGE_MODE black white
  settings_with_value "$SETTINGS_FILE" "$tmp_settings" SBMAGIC_PACKAGE_MODE "$package_mode"
  ensure_no_strategy_conflicts_files "$tmp_proxy" "$tmp_free_flow"

  old_settings_file="$SETTINGS_FILE"
  old_exclude_file="$EXCLUDE_FILE"
  old_include_file="$INCLUDE_FILE"
  old_proxy_packages_file="$PROXY_PACKAGES_FILE"
  old_free_flow_packages_file="$FREE_FLOW_PACKAGES_FILE"
  SETTINGS_FILE="$tmp_settings"
  EXCLUDE_FILE="$tmp_exclude"
  INCLUDE_FILE="$tmp_include"
  PROXY_PACKAGES_FILE="$tmp_proxy"
  FREE_FLOW_PACKAGES_FILE="$tmp_free_flow"
  if ! ( check_config_scratch ) >/dev/null 2>&1; then
    SETTINGS_FILE="$old_settings_file"
    EXCLUDE_FILE="$old_exclude_file"
    INCLUDE_FILE="$old_include_file"
    PROXY_PACKAGES_FILE="$old_proxy_packages_file"
    FREE_FLOW_PACKAGES_FILE="$old_free_flow_packages_file"
    rm -f "$tmp_mode" "$tmp_settings" "$tmp_exclude" "$tmp_include" "$tmp_proxy" "$tmp_free_flow"
    die "rendered config check failed for per-app settings; kept previous files"
  fi
  SETTINGS_FILE="$old_settings_file"
  EXCLUDE_FILE="$old_exclude_file"
  INCLUDE_FILE="$old_include_file"
  PROXY_PACKAGES_FILE="$old_proxy_packages_file"
  FREE_FLOW_PACKAGES_FILE="$old_free_flow_packages_file"

  cp -f "$SETTINGS_FILE" "$SETTINGS_FILE.bak" 2>/dev/null
  cp -f "$EXCLUDE_FILE" "$EXCLUDE_FILE.bak" 2>/dev/null
  cp -f "$INCLUDE_FILE" "$INCLUDE_FILE.bak" 2>/dev/null
  cp -f "$PROXY_PACKAGES_FILE" "$PROXY_PACKAGES_FILE.bak" 2>/dev/null
  cp -f "$FREE_FLOW_PACKAGES_FILE" "$FREE_FLOW_PACKAGES_FILE.bak" 2>/dev/null
  mv -f "$tmp_settings" "$SETTINGS_FILE"
  mv -f "$tmp_exclude" "$EXCLUDE_FILE"
  mv -f "$tmp_include" "$INCLUDE_FILE"
  mv -f "$tmp_proxy" "$PROXY_PACKAGES_FILE"
  mv -f "$tmp_free_flow" "$FREE_FLOW_PACKAGES_FILE"
  chmod 600 "$SETTINGS_FILE" "$EXCLUDE_FILE" "$INCLUDE_FILE" "$PROXY_PACKAGES_FILE" "$FREE_FLOW_PACKAGES_FILE"
  rm -f "$tmp_mode"
  log "config set per-app"
  trap - EXIT INT TERM HUP
  release_config_lock
  echo "ok"
}
