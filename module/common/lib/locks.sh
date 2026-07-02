# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

# mkdir is atomic, so it doubles as a portable mutex (no flock on Android).
# A lock whose owner pid is dead is reclaimed, so a killed magicctl cannot
# wedge future operations.
acquire_lock_dir() {
  lock_dir="$1"
  # The lock lives under RUNTIME_DIR; make sure the parent exists, otherwise
  # mkdir(lock) fails for a missing-parent reason and we'd spin the full retry
  # budget before wrongly reporting "another operation in progress".
  mkdir -p "$RUNTIME_DIR" 2>/dev/null
  i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lpid="$(cat "$lock_dir/owner" 2>/dev/null)"
    if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    i=$((i + 1))
    [ "$i" -gt 30 ] && return 1
    sleep 1
  done
  echo "$$" > "$lock_dir/owner"
  return 0
}

release_lock_dir() {
  rm -rf "$1"
}

acquire_start_lock() {
  acquire_lock_dir "$START_LOCK_DIR"
}

release_start_lock() {
  release_lock_dir "$START_LOCK_DIR"
}

acquire_config_lock() {
  acquire_lock_dir "$CONFIG_LOCK_DIR"
}

release_config_lock() {
  release_lock_dir "$CONFIG_LOCK_DIR"
}

acquire_watchdog_lock() {
  acquire_lock_dir "$WATCHDOG_LOCK_DIR"
}

release_watchdog_lock() {
  release_lock_dir "$WATCHDOG_LOCK_DIR"
}
