#!/system/bin/sh

MODDIR=${0%/*}
DATA_DIR=/data/adb/singbox_tun_Magic
CTL="$DATA_DIR/magicctl"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

sleep 5

if [ -x "$CTL" ]; then
  "$CTL" boot-dispatch >> "$DATA_DIR/logs/service.log" 2>&1 &
fi
