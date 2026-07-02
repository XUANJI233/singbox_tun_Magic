# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

mkdirs() {
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$RUNTIME_DIR" "$LOG_DIR" "$CACHE_DIR" "$RULESET_DIR"
}

log() {
  mkdirs
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$CONTROL_LOG"
}

die() {
  echo "ERROR: $*" >&2
  log "ERROR: $*"
  exit 1
}

random_token() {
  token=""
  if command -v od >/dev/null 2>&1; then
    token="$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  if [ -z "$token" ]; then
    token="$(date +%s)$$"
  fi
  echo "$token"
}

current_epoch() {
  now="$(date +%s 2>/dev/null || echo 0)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  echo "$now"
}
