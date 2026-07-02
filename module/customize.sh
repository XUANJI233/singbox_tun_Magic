SKIPUNZIP=1

ui_print "- Installing 星盘"

case "$ARCH" in
  arm64)
    SBMAGIC_ABI="arm64-v8a"
    ;;
  x64|x86_64)
    SBMAGIC_ABI="x86_64"
    ;;
  *)
    abort "- Unsupported architecture: $ARCH. Supported: arm64, x86_64"
    ;;
esac

if [ -z "$BOOTMODE" ]; then
  abort "- Recovery installation is not supported. Install from Magisk/KernelSU/APatch."
fi

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

DATA_DIR="/data/adb/singbox_tun_Magic"
BIN_DIR="$DATA_DIR/bin"
LIB_DIR="$DATA_DIR/lib"
CONFIG_DIR="$DATA_DIR/configs"
RUNTIME_DIR="$DATA_DIR/runtime"
LOG_DIR="$DATA_DIR/logs"
CACHE_DIR="$DATA_DIR/cache"
RULESET_DIR="$CACHE_DIR/rulesets"
SETTINGS_VERSION=2
MIGRATION_LOG="$LOG_DIR/install-migration.log"
MIGRATION_NOTICE_FILE="$RUNTIME_DIR/settings.migration.notice"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR" "$RUNTIME_DIR" "$LOG_DIR" "$CACHE_DIR" "$RULESET_DIR"

settings_get() {
  key="$1"
  [ -f "$CONFIG_DIR/settings.env" ] || return 0
  grep -m 1 "^$key=" "$CONFIG_DIR/settings.env" 2>/dev/null | cut -d= -f2-
}

settings_set() {
  key="$1"
  value="$2"
  file="$CONFIG_DIR/settings.env"
  if grep -q "^$key=" "$file" 2>/dev/null; then
    sed -i "s|^$key=.*|$key=$value|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

settings_version_value() {
  version="$(settings_get SBMAGIC_SETTINGS_VERSION)"
  case "$version" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$version" ;;
  esac
}

migrate_settings() {
  [ -f "$CONFIG_DIR/settings.env" ] || return 0

  old_version="$(settings_version_value)"
  notices=""
  if [ "$old_version" -lt 2 ] && [ "$(settings_get SBMAGIC_NETWORK_CHANGE_FLUSH)" = "true" ]; then
    settings_set SBMAGIC_NETWORK_CHANGE_FLUSH false
    notices="${notices}切换网络断开旧连接已关闭"
  fi
  settings_set SBMAGIC_SETTINGS_VERSION "$SETTINGS_VERSION"

  [ -n "$notices" ] || return 0
  {
    date '+%Y-%m-%d %H:%M:%S'
    echo "settings migration: $old_version -> $SETTINGS_VERSION; $notices"
  } >> "$MIGRATION_LOG"
  echo "已迁移旧设置:$notices" > "$MIGRATION_NOTICE_FILE"
}

cp -f "$MODPATH/bin/$SBMAGIC_ABI/sing-box" "$BIN_DIR/.core"
[ -f "$MODPATH/bin/$SBMAGIC_ABI/magic-fetch" ] && cp -f "$MODPATH/bin/$SBMAGIC_ABI/magic-fetch" "$BIN_DIR/magic-fetch"
[ -f "$MODPATH/bin/$SBMAGIC_ABI/magicctl-go" ] && cp -f "$MODPATH/bin/$SBMAGIC_ABI/magicctl-go" "$BIN_DIR/magicctl-go"
# applist.dex is ABI-independent dalvik bytecode (app-label dumper run via app_process)
[ -f "$MODPATH/bin/applist.dex" ] && cp -f "$MODPATH/bin/applist.dex" "$BIN_DIR/applist.dex"
cp -f "$MODPATH/common/magicctl" "$DATA_DIR/magicctl"
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"
cp -f "$MODPATH/common/lib/"*.sh "$LIB_DIR/"
chmod 755 "$BIN_DIR/.core" "$BIN_DIR/magic-fetch" "$BIN_DIR/magicctl-go" "$DATA_DIR/magicctl" 2>/dev/null

core_fp="$(stat -c '%s:%Y' "$BIN_DIR/.core" 2>/dev/null)"
core_version="$("$BIN_DIR/.core" version 2>/dev/null | head -1)"
if [ -n "$core_fp" ] && [ -n "$core_version" ]; then
  {
    echo "$core_fp"
    echo "$core_version"
  } > "$RUNTIME_DIR/core.version"
  chmod 600 "$RUNTIME_DIR/core.version" 2>/dev/null
fi

for name in settings.env outbounds.json packages.exclude packages.include packages.proxy packages.free-flow dns-direct-domains.txt; do
  if [ ! -f "$CONFIG_DIR/$name" ]; then
    cp -f "$MODPATH/defaults/$name" "$CONFIG_DIR/$name"
  else
    cp -f "$MODPATH/defaults/$name" "$CONFIG_DIR/$name.default"
  fi
done

migrate_settings

cp -f "$MODPATH/defaults/outbounds.example.json" "$CONFIG_DIR/outbounds.example.json"
if [ -d "$MODPATH/defaults/rulesets" ]; then
  cp -f "$MODPATH/defaults/rulesets/"*.srs "$RULESET_DIR/" 2>/dev/null || true
  chmod 600 "$RULESET_DIR/"*.srs 2>/dev/null || true
fi
echo "$MODPATH" > "$RUNTIME_DIR/module.path"

chmod 700 "$DATA_DIR" "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR" "$RUNTIME_DIR" "$LOG_DIR" "$CACHE_DIR"
chmod 600 "$LIB_DIR"/*.sh 2>/dev/null
chmod 600 "$CONFIG_DIR"/* 2>/dev/null
chmod 644 "$CONFIG_DIR/outbounds.example.json" "$CONFIG_DIR"/*.default 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$DATA_DIR" 0 0 0700 0600
set_perm "$BIN_DIR/.core" 0 0 0755
[ -f "$BIN_DIR/magic-fetch" ] && set_perm "$BIN_DIR/magic-fetch" 0 0 0755
[ -f "$BIN_DIR/magicctl-go" ] && set_perm "$BIN_DIR/magicctl-go" 0 0 0755
set_perm_recursive "$LIB_DIR" 0 0 0700 0600
set_perm "$DATA_DIR/magicctl" 0 0 0755

ui_print "- ABI: $SBMAGIC_ABI"
ui_print "- Data dir: $DATA_DIR"
ui_print "- Edit $CONFIG_DIR/outbounds.json to add your node"
ui_print "- Control: $DATA_DIR/magicctl start|stop|restart|status|check|logs"
ui_print "- WebUI: open this module from KernelSU Manager / KsuWebUI standalone app"
