# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

cleanup_stale_process_binaries() {
  [ -f "$CORE_BIN" ] || return 0
  for candidate in "$BIN_DIR"/* "$BIN_DIR"/.[!.]* "$BIN_DIR"/..?*; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
      "$CORE_BIN"|"$SING_BOX"|"$FETCHER"|"$RENDERER"|"$APPLIST_DEX")
        continue
      ;;
    esac
    [ -f "$candidate" ] || continue
    if same_file "$CORE_BIN" "$candidate" || same_file_fingerprint "$CORE_BIN" "$candidate"; then
      rm -f "$candidate"
    fi
  done
}

same_file() {
  [ "$1" -ef "$2" ] 2>/dev/null
}

file_fingerprint() {
  stat -c '%s:%Y' "$1" 2>/dev/null
}

core_version() {
  version_bin=""
  if [ -x "$CORE_BIN" ]; then
    version_bin="$CORE_BIN"
  elif [ -x "$SING_BOX" ]; then
    version_bin="$SING_BOX"
  else
    return 0
  fi
  version_fp="$(file_fingerprint "$version_bin")"
  [ -n "$version_fp" ] || return 0
  if [ -f "$CORE_VERSION_FILE" ]; then
    cached_fp="$(sed -n '1p' "$CORE_VERSION_FILE" 2>/dev/null)"
    cached_version="$(sed -n '2p' "$CORE_VERSION_FILE" 2>/dev/null)"
    if [ "$cached_fp" = "$version_fp" ] && [ -n "$cached_version" ]; then
      echo "$cached_version"
      return 0
    fi
  fi
  current_version="$("$version_bin" version 2>/dev/null | head -1)"
  [ -n "$current_version" ] || return 0
  tmp="$CORE_VERSION_FILE.$$"
  {
    echo "$version_fp"
    echo "$current_version"
  } > "$tmp" && mv -f "$tmp" "$CORE_VERSION_FILE"
  chmod 600 "$CORE_VERSION_FILE" 2>/dev/null
  echo "$current_version"
}

same_file_fingerprint() {
  fp_a="$(file_fingerprint "$1")"
  fp_b="$(file_fingerprint "$2")"
  [ -n "$fp_a" ] && [ "$fp_a" = "$fp_b" ]
}

process_binary_fresh() {
  [ -x "$SING_BOX" ] || return 1
  same_file "$CORE_BIN" "$SING_BOX" && return 0
  core_fp="$(file_fingerprint "$CORE_BIN")"
  process_fp="$(file_fingerprint "$SING_BOX")"
  [ -n "$core_fp" ] && [ "$core_fp" = "$process_fp" ]
}

prepare_process_binary() {
  mkdirs
  set_process_binary_path
  [ -x "$CORE_BIN" ] || die "core binary missing: $CORE_BIN"
  if [ "$SING_BOX" != "$CORE_BIN" ]; then
    if ! process_binary_fresh; then
      tmp="$RUNTIME_DIR/process-bin.$$"
      rm -f "$tmp"
      ln "$CORE_BIN" "$tmp" 2>/dev/null || cp -p "$CORE_BIN" "$tmp" 2>/dev/null || cp -f "$CORE_BIN" "$tmp" || {
        rm -f "$tmp"
        die "failed to prepare process binary: $SING_BOX"
      }
      chmod 755 "$tmp"
      mv -f "$tmp" "$SING_BOX" || {
        rm -f "$tmp"
        die "failed to install process binary: $SING_BOX"
      }
    fi
    cleanup_stale_process_binaries
  fi
}

pid_alive() {
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  saved_process="$(cat "$PROCESS_FILE" 2>/dev/null)"
  case "$cmdline" in
    *"$SING_BOX"*) return 0 ;;
  esac
  if [ -n "$saved_process" ]; then
    case "$cmdline" in
      *"$saved_process"*) return 0 ;;
    esac
  fi
  return 1
}

watchdog_alive() {
  [ -f "$WATCHDOG_PID_FILE" ] || return 1
  wpid="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)"
  [ -n "$wpid" ] || return 1
  kill -0 "$wpid" 2>/dev/null || return 1
  cmdline="$(tr '\000' ' ' < "/proc/$wpid/cmdline" 2>/dev/null)"
  case "$cmdline" in
    *"magicctl"*"watchdog"*) return 0 ;;
    *) return 1 ;;
  esac
}

netwatch_alive() {
  [ -f "$NETWATCH_PID_FILE" ] || return 1
  npid="$(cat "$NETWATCH_PID_FILE" 2>/dev/null)"
  [ -n "$npid" ] || return 1
  kill -0 "$npid" 2>/dev/null || return 1
  cmdline="$(tr '\000' ' ' < "/proc/$npid/cmdline" 2>/dev/null)"
  case "$cmdline" in
    *"magicctl"*"netwatch"*) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_service_start() {
  i=0
  saw_pid=false
  while [ "$i" -lt 20 ]; do
    if service_ready_after_start; then
      return 0
    fi
    pid_alive && saw_pid=true
    if ! watchdog_alive; then
      [ "$saw_pid" = "true" ] && return 0
      sleep 1
      i=$((i + 1))
      continue
    fi
    sleep 1
    i=$((i + 1))
  done
  service_ready_after_start || [ "$saw_pid" = "true" ]
}

watchdog_interval_seconds() {
  interval="$SBMAGIC_WATCHDOG_INTERVAL"
  case "$interval" in
    ''|*[!0-9]*) interval=300 ;;
  esac
  [ "$interval" -lt 60 ] && interval=60
  echo "$interval"
}

apply_oom_score_adj() {
  pid="$1"
  label="$2"
  [ "$SBMAGIC_OOM_PROTECT" = "true" ] || return 0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  target="/proc/$pid/oom_score_adj"
  if [ ! -w "$target" ]; then
    log "oom protect skipped for $label pid=$pid: $target is not writable"
    return 0
  fi
  if echo "$SBMAGIC_OOM_SCORE_ADJ" > "$target" 2>/dev/null; then
    log "oom protect active for $label pid=$pid oom_score_adj=$SBMAGIC_OOM_SCORE_ADJ"
  else
    log "oom protect failed for $label pid=$pid"
  fi
}
