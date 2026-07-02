# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

load_settings() {
  load_settings_values
  set_process_binary_path
  validate_interface_name
  validate_settings
}

set_process_binary_path() {
  case "$SBMAGIC_PROCESS_NAME" in
    ""|"."|".."|*/*|*\\*|*[!A-Za-z0-9._-]*)
      die "invalid SBMAGIC_PROCESS_NAME: use only A-Z a-z 0-9 . _ -"
      ;;
  esac
  SING_BOX="$BIN_DIR/$SBMAGIC_PROCESS_NAME"
}

set_process_binary_path_relaxed() {
  case "$SBMAGIC_PROCESS_NAME" in
    ""|"."|".."|*/*|*\\*|*[!A-Za-z0-9._-]*)
      saved_process="$(cat "$PROCESS_FILE" 2>/dev/null)"
      SING_BOX="${saved_process:-$BIN_DIR/netd-helper}"
      return 1
      ;;
  esac
  SING_BOX="$BIN_DIR/$SBMAGIC_PROCESS_NAME"
  return 0
}

validate_interface_name() {
  case "$SBMAGIC_INTERFACE" in
    ""|*/*|*\\*|*[!A-Za-z0-9._-]*)
      die "invalid SBMAGIC_INTERFACE: use only A-Z a-z 0-9 . _ -"
      ;;
  esac
  [ "${#SBMAGIC_INTERFACE}" -le 15 ] || die "invalid SBMAGIC_INTERFACE: Linux interface names must be 15 bytes or shorter"
}
