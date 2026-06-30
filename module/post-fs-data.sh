#!/system/bin/sh

MODDIR=${0%/*}
DATA_DIR=/data/adb/singbox_tun_Magic

mkdir -p "$DATA_DIR/runtime"
echo "$MODDIR" > "$DATA_DIR/runtime/module.path"
