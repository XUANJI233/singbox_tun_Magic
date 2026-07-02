# shellcheck shell=sh
# Loaded by magicctl. Do not execute directly.

package_file_has_entries() {
  file="$1"
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "" && line !~ /^#/) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null
}

package_file_entry_count() {
  file="$1"
  [ -f "$file" ] || { echo 0; return 0; }
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "" && line !~ /^#/) count++
    }
    END { print count + 0 }
  ' "$file" 2>/dev/null
}

package_database_readable_text() {
  if [ -r "$ANDROID_PACKAGES_XML" ]; then
    echo true
  else
    echo false
  fi
}

validate_package_database_access() {
  case "$SBMAGIC_PACKAGE_MODE" in
    white)
      package_file_has_entries "$INCLUDE_FILE" || return 0
      ;;
    *)
      package_file_has_entries "$EXCLUDE_FILE" || return 0
      ;;
  esac
  [ -r "$ANDROID_PACKAGES_XML" ] || die "cannot read $ANDROID_PACKAGES_XML; package-based TUN entry filtering would not resolve app UIDs"
}

first_package_conflict_files() {
  proxy_file="$1"
  free_flow_file="$2"
  awk '
    FNR == NR {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "" && line !~ /^#/) seen[line] = 1
      next
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "" && line !~ /^#/ && seen[line]) {
        print line
        exit
      }
    }
  ' "$proxy_file" "$free_flow_file" 2>/dev/null
}

first_package_conflict() {
  first_package_conflict_files "$PROXY_PACKAGES_FILE" "$FREE_FLOW_PACKAGES_FILE"
}

ensure_no_strategy_conflicts() {
  conflict="$(first_package_conflict)"
  [ -z "$conflict" ] || die "package exists in both packages.proxy and packages.free-flow: $conflict"
}

ensure_no_strategy_conflicts_files() {
  conflict="$(first_package_conflict_files "$1" "$2")"
  [ -z "$conflict" ] || die "package exists in both packages.proxy and packages.free-flow: $conflict"
}

filter_applist_scope() {
  case "$1" in
    user|system)
      awk -F '	' -v scope="$1" '$3 == scope'
      ;;
    *)
      cat
      ;;
  esac
}

# Dump "package<TAB>label<TAB>user|system" for installed apps in ONE
# app_process run (resolves localized labels via PackageManager -- pm/dumpsys
# expose no labels, and per-apk aapt would be hundreds of spawns). If this
# path breaks, fail loudly instead of silently degrading to package names.

applist() {
  scope="$1"
  [ -f "$APPLIST_DEX" ] || die "applist.dex missing: $APPLIST_DEX"
  command -v app_process >/dev/null 2>&1 || die "app_process missing"
  out="$(CLASSPATH="$APPLIST_DEX" app_process /system/bin AppList 2>/dev/null)"
  [ -n "$out" ] || die "failed to read installed app labels"
  printf '%s\n' "$out" | sort -f -t "$(printf '\t')" -k2 | filter_applist_scope "$scope"
}
