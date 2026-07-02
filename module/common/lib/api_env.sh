# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

random_api_port() {
  n=""
  if command -v od >/dev/null 2>&1; then
    n="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  case "$n" in ''|*[!0-9]*) n="$(date +%s)" ;; esac
  # Stay BELOW the Linux ephemeral range (ip_local_port_range is 32768-60999 on
  # Android). A persisted random port that overlapped the ephemeral range could
  # one day collide with a transient socket at boot, the clash_api bind would
  # fail, and the watchdog would keep retrying the same dead port. 20000-31999
  # avoids that window entirely.
  echo $((20000 + (n % 12000)))
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

write_api_env() {
  {
    echo "SBMAGIC_API_SECRET=$SBMAGIC_API_SECRET"
    echo "SBMAGIC_API_PORT=$SBMAGIC_API_PORT"
  } > "$API_ENV_FILE"
  chmod 600 "$API_ENV_FILE"
}

ensure_api_env() {
  mkdirs
  configured_port="$SBMAGIC_API_PORT"
  if [ -f "$API_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$API_ENV_FILE"
  fi
  rewrite_api_env=false
  if [ -z "$SBMAGIC_API_SECRET" ]; then
    SBMAGIC_API_SECRET="$(random_token)"
    rewrite_api_env=true
  fi
  case "$configured_port" in
    auto|AUTO|"")
      if ! valid_port "$SBMAGIC_API_PORT"; then
        SBMAGIC_API_PORT="$(random_api_port)"
        rewrite_api_env=true
      fi
      ;;
    *)
      valid_port "$configured_port" || die "invalid SBMAGIC_API_PORT '$configured_port': use auto or a port from 1 to 65535"
      [ "$SBMAGIC_API_PORT" != "$configured_port" ] && rewrite_api_env=true
      SBMAGIC_API_PORT="$configured_port"
      ;;
  esac
  $rewrite_api_env && write_api_env
}
