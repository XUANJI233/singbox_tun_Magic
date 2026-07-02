# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

rule_sets_used() {
  [ "$SBMAGIC_PROXY_RULE_MODE" = "bypass-cn" ]
}

# Fetch a subscription URL from root. Done here (not via the WebView's
# fetch()) so it bypasses CORS and can reach the URL over whatever routing is
# currently active. Returns the raw body; the WebUI decodes/parses it. A
# v2rayN-style User-Agent nudges most panels into returning the universal
# base64 share-link list rather than a Clash YAML.
fetch_url() {
  url="$1"
  [ -n "$url" ] || die "usage: fetch URL"
  case "$url" in
    http://*|https://*) ;;
    *) die "fetch only accepts http(s) URLs" ;;
  esac
  [ -x "$FETCHER" ] || die "magic-fetch missing: $FETCHER"
  "$FETCHER" "$url" "v2rayN/6.42" || die "fetch failed"
}

download_ruleset() {
  url="$1"
  dest="$2"
  [ -x "$FETCHER" ] || die "magic-fetch missing: $FETCHER"
  tmp="$dest.tmp.$$"
  rm -f "$tmp"
  if "$FETCHER" "$url" "singbox_tun_Magic/1.0" > "$tmp"; then
    if [ -s "$tmp" ]; then
      mv -f "$tmp" "$dest"
      chmod 600 "$dest"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

ruleset_refresh() {
  mkdirs
  load_settings
  download_ruleset "$GEOSITE_CN_RULESET_URL" "$GEOSITE_CN_RULESET" || die "failed to download geosite-cn rule-set"
  download_ruleset "$GEOIP_CN_RULESET_URL" "$GEOIP_CN_RULESET" || die "failed to download geoip-cn rule-set"
  rm -f "$CACHE_DIR/cache.db" "$CACHE_DIR/cache.db-"* 2>/dev/null
  log "rule-set files refreshed"
  if rule_sets_used && pid_alive; then
    log "rule-set active; reloading service"
    reload_service
  else
    echo "ruleset_refreshed=true"
  fi
}
