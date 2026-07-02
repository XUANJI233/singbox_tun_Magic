# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

nc_with_timeout() {
  # -w is nc's own connection/idle timeout, present on BSD/GNU/busybox/toybox
  # nc alike -- kept even when the external `timeout` binary is available so a
  # hung/half-open socket can't block this call forever on a device that lacks
  # `timeout` (nc would otherwise wait indefinitely with no safety net).
  if command -v timeout >/dev/null 2>&1; then
    timeout "$API_MAX_TIME" nc -w "$API_MAX_TIME" "$@"
  else
    nc -w "$API_MAX_TIME" "$@"
  fi
}

api_call_nc() {
  method="$1"
  path="$2"
  body="$3"
  command -v nc >/dev/null 2>&1 || return 127
  api_response_file="$RUNTIME_DIR/api-response.$$"
  if [ -n "$body" ]; then
    {
      printf '%s %s HTTP/1.1\r\n' "$method" "$path"
      printf 'Host: %s:%s\r\n' "$SBMAGIC_API_HOST" "$SBMAGIC_API_PORT"
      printf 'Authorization: Bearer %s\r\n' "$SBMAGIC_API_SECRET"
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "${#body}"
      printf 'Connection: close\r\n\r\n'
      printf '%s' "$body"
    } | nc_with_timeout "$SBMAGIC_API_HOST" "$SBMAGIC_API_PORT" > "$api_response_file"
  else
    {
      printf '%s %s HTTP/1.1\r\n' "$method" "$path"
      printf 'Host: %s:%s\r\n' "$SBMAGIC_API_HOST" "$SBMAGIC_API_PORT"
      printf 'Authorization: Bearer %s\r\n' "$SBMAGIC_API_SECRET"
      printf 'Connection: close\r\n\r\n'
    } | nc_with_timeout "$SBMAGIC_API_HOST" "$SBMAGIC_API_PORT" > "$api_response_file"
  fi
  api_status="$(head -1 "$api_response_file" 2>/dev/null | awk '{print $2}')"
  sed '1,/^\r$/d' "$api_response_file"
  rm -f "$api_response_file"
  case "$api_status" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

api_call_once() {
  method="$1"
  path="$2"
  body="$3"
  if [ -n "$body" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --connect-timeout "$API_CONNECT_TIMEOUT" --max-time "$API_MAX_TIME" -X "$method" -H "Authorization: Bearer $SBMAGIC_API_SECRET" -H "Content-Type: application/json" -d "$body" "http://$SBMAGIC_API_HOST:$SBMAGIC_API_PORT$path"
    else
      api_call_nc "$method" "$path" "$body"
    fi
  else
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --connect-timeout "$API_CONNECT_TIMEOUT" --max-time "$API_MAX_TIME" -X "$method" -H "Authorization: Bearer $SBMAGIC_API_SECRET" "http://$SBMAGIC_API_HOST:$SBMAGIC_API_PORT$path"
    else
      api_call_nc "$method" "$path" ""
    fi
  fi
}

api_call() {
  method="$1"
  path="$2"
  body="$3"
  load_settings
  ensure_api_env
  [ -n "$method" ] && [ -n "$path" ] || die "usage: api METHOD PATH [JSON]"
  case "$path" in /*) ;; *) die "api path must start with /" ;; esac
  pid_alive || die "sing-box API is not running"

  api_call_out="$RUNTIME_DIR/api-call.$$"
  api_call_err="$RUNTIME_DIR/api-call.$$.err"
  i=0
  while [ "$i" -lt "$API_RETRIES" ]; do
    if api_call_once "$method" "$path" "$body" > "$api_call_out" 2> "$api_call_err"; then
      cat "$api_call_out"
      rm -f "$api_call_out" "$api_call_err"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$API_RETRIES" ] && sleep 1
  done
  cat "$api_call_out" 2>/dev/null
  cat "$api_call_err" >&2 2>/dev/null
  rm -f "$api_call_out" "$api_call_err"
  return 1
}

api_health_ok() {
  pid_alive || return 1
  ensure_api_env
  old_connect_timeout="$API_CONNECT_TIMEOUT"
  old_max_time="$API_MAX_TIME"
  old_retries="$API_RETRIES"
  API_CONNECT_TIMEOUT=1
  API_MAX_TIME=1
  API_RETRIES=1
  api_call_once GET /configs "" >/dev/null 2>&1
  rc=$?
  API_CONNECT_TIMEOUT="$old_connect_timeout"
  API_MAX_TIME="$old_max_time"
  API_RETRIES="$old_retries"
  return "$rc"
}

api_health_ok_after_retries() {
  attempts="$1"
  delay="$2"
  case "$attempts" in ''|*[!0-9]*) attempts=2 ;; esac
  case "$delay" in ''|*[!0-9]*) delay=1 ;; esac
  i=0
  while [ "$i" -lt "$attempts" ]; do
    api_health_ok && return 0
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] && sleep "$delay"
  done
  return 1
}
