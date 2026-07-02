# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

config_file_for() {
  case "$1" in
    settings) echo "$SETTINGS_FILE" ;;
    outbounds) echo "$OUTBOUNDS_FILE" ;;
    exclude) echo "$EXCLUDE_FILE" ;;
    include) echo "$INCLUDE_FILE" ;;
    proxy-packages|packages-proxy) echo "$PROXY_PACKAGES_FILE" ;;
    free-flow-packages|packages-free-flow) echo "$FREE_FLOW_PACKAGES_FILE" ;;
    dns-direct) echo "$DNS_DIRECT_FILE" ;;
    *) return 1 ;;
  esac
}

config_get() {
  file="$(config_file_for "$1")" || die "unknown config key: $1"
  cat "$file" 2>/dev/null
}

config_set() {
  key="$1"
  file="$(config_file_for "$key")" || die "unknown config key: $key"
  acquire_config_lock || die "another config operation is already in progress"
  tmp=""
  trap '[ -n "$tmp" ] && rm -f "$tmp"; release_config_lock' EXIT INT TERM HUP
  mkdirs
  tmp="$file.tmp.$$"
  cat > "$tmp"
  if [ "$key" = "outbounds" ]; then
    if [ -x "$FETCHER" ]; then
      "$FETCHER" --validate-outbounds "$tmp" || { rm -f "$tmp"; die "invalid outbounds"; }
    else
      command -v python3 >/dev/null 2>&1 && { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" || { rm -f "$tmp"; die "invalid JSON for $key"; }; }
    fi
  fi
  cp -f "$file" "$file.bak" 2>/dev/null
  mv -f "$tmp" "$file"
  chmod 600 "$file"
  if config_requires_check "$key" && ! ( check_config_scratch ) >/dev/null 2>&1; then
    mv -f "$file.bak" "$file" 2>/dev/null
    chmod 600 "$file" 2>/dev/null
    die "rendered config check failed for $key; restored previous file"
  fi
  log "config set $key"
  trap - EXIT INT TERM HUP
  release_config_lock
  echo "ok"
}

config_requires_check() {
  case "$1" in
    settings|outbounds|exclude|include|proxy-packages|packages-proxy|free-flow-packages|packages-free-flow|dns-direct) return 0 ;;
    *) return 1 ;;
  esac
}

# Swap a config file with its .bak side by side, so calling this twice in
# a row is a no-op (toggle, not a one-way trip). Pairs with config_set's
# automatic backup-before-overwrite.

config_rollback() {
  key="$1"
  file="$(config_file_for "$key")" || die "unknown config key: $key"
  acquire_config_lock || die "another config operation is already in progress"
  trap 'release_config_lock' EXIT INT TERM HUP
  [ -f "$file.bak" ] || die "no backup available for $key"
  tmp="$file.swap.$$"
  mv -f "$file" "$tmp"
  mv -f "$file.bak" "$file"
  mv -f "$tmp" "$file.bak"
  chmod 600 "$file" "$file.bak" 2>/dev/null
  log "config rollback $key"
  trap - EXIT INT TERM HUP
  release_config_lock
  echo "ok"
}
