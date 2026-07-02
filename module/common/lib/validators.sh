# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

validate_one_of() {
  value="$1"
  name="$2"
  shift 2
  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return 0
  done
  die "invalid $name '$value': use one of: $*"
}

validate_uint_range() {
  value="$1"
  name="$2"
  min="$3"
  max="$4"
  case "$value" in
    ''|*[!0-9]*) die "invalid $name '$value': use an integer from $min to $max" ;;
  esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || die "invalid $name '$value': use an integer from $min to $max"
}

validate_int_range() {
  value="$1"
  name="$2"
  min="$3"
  max="$4"
  number="$value"
  case "$number" in
    -*) number="${number#-}" ;;
  esac
  case "$number" in
    ''|*[!0-9]*) die "invalid $name '$value': use an integer from $min to $max" ;;
  esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || die "invalid $name '$value': use an integer from $min to $max"
}

validate_duration_literal() {
  value="$1"
  name="$2"
  case "$value" in
    ''|*\"*|*\\*|*/*|*[!0-9A-Za-z.µ]*)
      die "invalid $name '$value': use a Go duration like 100ms, 1s, or 168h"
      ;;
  esac
}

validate_ipv4_literal() {
  value="$1"
  case "$value" in
    *..*|.*|*.|*[!0-9.]*)
      return 1
      ;;
  esac

  old_ifs="$IFS"
  IFS=.
  # shellcheck disable=SC2086
  set -- $value
  IFS="$old_ifs"
  [ "$#" -eq 4 ] || return 1

  for octet in "$@"; do
    case "$octet" in
      ''|*[!0-9]*)
        return 1
        ;;
    esac
    [ "$octet" -le 255 ] || return 1
  done
}

validate_ipv6_literal() {
  value="$1"
  printf '%s\n' "$value" | awk '
    function fail() { exit 1 }
    {
      s = $0
      if (s !~ /^[0-9A-Fa-f:]+$/) fail()
      if (s !~ /:/) fail()
      if (s ~ /:::/) fail()
      if (s ~ /^:[^:]/ || s ~ /[^:]:$/) fail()
      t = s
      compressed = gsub(/::/, "", t)
      if (compressed > 1) fail()
      count = split(s, parts, ":")
      groups = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] == "") continue
        if (parts[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) fail()
        groups++
      }
      if (compressed == 0 && groups != 8) fail()
      if (compressed == 1 && (groups == 0 || groups >= 8)) fail()
      ok = 1
    }
    END { exit ok ? 0 : 1 }
  '
}

validate_ipv4_cidr_literal() {
  cidr_value="$1"
  cidr_name="$2"
  case "$cidr_value" in
    */*)
      cidr_ip="${cidr_value%/*}"
      cidr_prefix="${cidr_value#*/}"
      ;;
    *)
      die "invalid $cidr_name '$cidr_value': use an IPv4 CIDR like 198.18.0.0/15"
      ;;
  esac
  validate_ipv4_literal "$cidr_ip" || die "invalid $cidr_name '$cidr_value': use an IPv4 CIDR like 198.18.0.0/15"
  case "$cidr_prefix" in
    ''|*[!0-9]*) die "invalid $cidr_name '$cidr_value': CIDR prefix must be 0..32" ;;
  esac
  [ "$cidr_prefix" -le 32 ] || die "invalid $cidr_name '$cidr_value': CIDR prefix must be 0..32"
}

validate_ipv6_cidr_literal() {
  cidr_value="$1"
  cidr_name="$2"
  case "$cidr_value" in
    */*)
      cidr_ip="${cidr_value%/*}"
      cidr_prefix="${cidr_value#*/}"
      ;;
    *)
      die "invalid $cidr_name '$cidr_value': use an IPv6 CIDR like fc00::/18"
      ;;
  esac
  validate_ipv6_literal "$cidr_ip" || die "invalid $cidr_name '$cidr_value': use an IPv6 CIDR like fc00::/18"
  case "$cidr_prefix" in
    ''|*[!0-9]*) die "invalid $cidr_name '$cidr_value': CIDR prefix must be 0..128" ;;
  esac
  [ "$cidr_prefix" -le 128 ] || die "invalid $cidr_name '$cidr_value': CIDR prefix must be 0..128"
}

validate_dns_server_literal() {
  value="$1"
  name="$2"
  case "$value" in
    ''|*://*|*/*|*\\*|*\"*|*\[*|*\]*|*%*|*,*|*" "*)
      die "invalid $name '$value': use an IP literal, not a hostname or URL"
      ;;
  esac
  if validate_ipv4_literal "$value" || validate_ipv6_literal "$value"; then
    return 0
  fi
  die "invalid $name '$value': use an IP literal, not a hostname or URL"
}

validate_dns_tls_server_name() {
  value="$1"
  name="$2"
  [ -z "$value" ] && return 0
  case "$value" in
    *://*|*/*|*\\*|*\"*|*\[*|*\]*|*%*|*,*|*" "*|*:*|.*|*.)
      die "invalid $name '$value': use a DNS name like cloudflare-dns.com"
      ;;
  esac
  printf '%s\n' "$value" | awk '
    function fail() { exit 1 }
    {
      if (length($0) > 253) fail()
      n = split($0, labels, ".")
      if (n < 2) fail()
      for (i = 1; i <= n; i++) {
        label = labels[i]
        if (length(label) < 1 || length(label) > 63) fail()
        if (label !~ /^[A-Za-z0-9-]+$/) fail()
        if (label ~ /^-/ || label ~ /-$/) fail()
      }
      ok = 1
    }
    END { exit ok ? 0 : 1 }
  ' || die "invalid $name '$value': use a DNS name like cloudflare-dns.com"
}

json_bool() {
  case "$1" in
    true) echo true ;;
    false|"") echo false ;;
    *) die "invalid boolean '$1': use true or false" ;;
  esac
}
