# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

validate_settings() {
  json_bool "$SBMAGIC_ENABLED" >/dev/null
  json_bool "$SBMAGIC_BOOT_START" >/dev/null
  json_bool "$SBMAGIC_INIT_SERVICE" >/dev/null
  json_bool "$SBMAGIC_WATCHDOG" >/dev/null
  json_bool "$SBMAGIC_NETWORK_WATCH" >/dev/null
  json_bool "$SBMAGIC_NETWORK_CHANGE_FLUSH" >/dev/null
  json_bool "$SBMAGIC_IPV6" >/dev/null
  json_bool "$SBMAGIC_AUTO_ROUTE" >/dev/null
  json_bool "$SBMAGIC_AUTO_REDIRECT" >/dev/null
  json_bool "$SBMAGIC_ENDPOINT_INDEPENDENT_NAT" >/dev/null
  json_bool "$SBMAGIC_REJECT_QUIC" >/dev/null
  json_bool "$SBMAGIC_STRICT_ROUTE" >/dev/null
  json_bool "$SBMAGIC_API_FIREWALL" >/dev/null
  json_bool "$SBMAGIC_SNIFF" >/dev/null
  json_bool "$SBMAGIC_OOM_PROTECT" >/dev/null
  json_bool "$SBMAGIC_DNS_REVERSE_MAPPING" >/dev/null

  validate_uint_range "$SBMAGIC_WATCHDOG_INTERVAL" SBMAGIC_WATCHDOG_INTERVAL 60 86400
  validate_uint_range "$SBMAGIC_SETTINGS_VERSION" SBMAGIC_SETTINGS_VERSION 1 999
  validate_uint_range "$SBMAGIC_NETWORK_RECOVERY_COOLDOWN" SBMAGIC_NETWORK_RECOVERY_COOLDOWN 5 3600
  validate_uint_range "$SBMAGIC_NETWORK_SETTLE_DELAY" SBMAGIC_NETWORK_SETTLE_DELAY 0 30
  validate_uint_range "$SBMAGIC_NETWORK_HEALTH_RETRIES" SBMAGIC_NETWORK_HEALTH_RETRIES 1 10
  validate_uint_range "$SBMAGIC_NETWORK_HEALTH_RETRY_DELAY" SBMAGIC_NETWORK_HEALTH_RETRY_DELAY 0 30
  validate_uint_range "$SBMAGIC_NETWORK_OWN_TUN_GRACE" SBMAGIC_NETWORK_OWN_TUN_GRACE 0 120
  validate_uint_range "$SBMAGIC_MTU" SBMAGIC_MTU 1200 9000
  validate_int_range "$SBMAGIC_OOM_SCORE_ADJ" SBMAGIC_OOM_SCORE_ADJ -1000 1000
  validate_one_of "$SBMAGIC_STACK" SBMAGIC_STACK gvisor system mixed
  validate_one_of "$SBMAGIC_TCP_CONGESTION_CONTROL" SBMAGIC_TCP_CONGESTION_CONTROL system bbr cubic reno
  validate_one_of "$SBMAGIC_UDP_NATIVE_MODE" SBMAGIC_UDP_NATIVE_MODE off quic
  validate_one_of "$SBMAGIC_IPV6_MODE" SBMAGIC_IPV6_MODE auto proxy block off
  validate_one_of "$SBMAGIC_PACKAGE_MODE" SBMAGIC_PACKAGE_MODE black white
  validate_one_of "$SBMAGIC_PROXY_RULE_MODE" SBMAGIC_PROXY_RULE_MODE off global bypass-cn
  validate_one_of "$SBMAGIC_FREE_FLOW_RULE_MODE" SBMAGIC_FREE_FLOW_RULE_MODE off global
  validate_one_of "$SBMAGIC_MIXED_RULE_PRIORITY" SBMAGIC_MIXED_RULE_PRIORITY proxy free-flow
  validate_one_of "$SBMAGIC_DNS_MODE" SBMAGIC_DNS_MODE real-ip fake-ip
  validate_one_of "$SBMAGIC_DNS_STRATEGY" SBMAGIC_DNS_STRATEGY ipv4_only prefer_ipv4 prefer_ipv6 ipv6_only
  validate_one_of "$SBMAGIC_DNS_LOCAL_TYPE" SBMAGIC_DNS_LOCAL_TYPE https tls quic h3 udp tcp
  validate_one_of "$SBMAGIC_DNS_REMOTE_TYPE" SBMAGIC_DNS_REMOTE_TYPE https tls quic h3 udp tcp
  validate_one_of "$SBMAGIC_DNS_FINAL" SBMAGIC_DNS_FINAL remote local
  validate_one_of "$SBMAGIC_API_MODE" SBMAGIC_API_MODE Rule Global Direct
  validate_one_of "$SBMAGIC_RULESET_DOWNLOAD_DETOUR" SBMAGIC_RULESET_DOWNLOAD_DETOUR proxy direct
  validate_dns_server_literal "$SBMAGIC_DNS_LOCAL_SERVER" SBMAGIC_DNS_LOCAL_SERVER
  validate_dns_server_literal "$SBMAGIC_DNS_REMOTE_SERVER" SBMAGIC_DNS_REMOTE_SERVER
  validate_dns_tls_server_name "$SBMAGIC_DNS_LOCAL_TLS_SERVER_NAME" SBMAGIC_DNS_LOCAL_TLS_SERVER_NAME
  validate_dns_tls_server_name "$SBMAGIC_DNS_REMOTE_TLS_SERVER_NAME" SBMAGIC_DNS_REMOTE_TLS_SERVER_NAME
  if [ "$SBMAGIC_DNS_MODE" = "fake-ip" ]; then
    validate_ipv4_cidr_literal "$SBMAGIC_FAKEIP4" SBMAGIC_FAKEIP4
    if [ "$SBMAGIC_IPV6" = "true" ]; then
      validate_ipv6_cidr_literal "$SBMAGIC_FAKEIP6" SBMAGIC_FAKEIP6
    fi
  fi
  validate_duration_literal "$SBMAGIC_SNIFF_TIMEOUT" SBMAGIC_SNIFF_TIMEOUT
  validate_duration_literal "$SBMAGIC_RULE_UPDATE_INTERVAL" SBMAGIC_RULE_UPDATE_INTERVAL
  if [ "$SBMAGIC_UDP_TIMEOUT" != "auto" ]; then
    validate_duration_literal "$SBMAGIC_UDP_TIMEOUT" SBMAGIC_UDP_TIMEOUT
  fi
  if [ "$SBMAGIC_IPV6_MODE" != "proxy" ] && [ "$SBMAGIC_DNS_STRATEGY" = "ipv6_only" ]; then
    die "SBMAGIC_DNS_STRATEGY=ipv6_only requires SBMAGIC_IPV6_MODE=proxy"
  fi
  if [ "$SBMAGIC_AUTO_REDIRECT" = "true" ] && [ "$SBMAGIC_AUTO_ROUTE" != "true" ]; then
    die "SBMAGIC_AUTO_REDIRECT=true requires SBMAGIC_AUTO_ROUTE=true"
  fi
  if [ "$SBMAGIC_UDP_NATIVE_MODE" != "off" ] && [ -z "$SBMAGIC_UDP_NATIVE_OUTBOUND" ]; then
    die "SBMAGIC_UDP_NATIVE_OUTBOUND is required when SBMAGIC_UDP_NATIVE_MODE=$SBMAGIC_UDP_NATIVE_MODE"
  fi
}
