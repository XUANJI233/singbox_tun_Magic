#!/system/bin/sh

DATA_DIR=/data/adb/singbox_tun_Magic
CTL="$DATA_DIR/magicctl"

if [ ! -x "$CTL" ]; then
  echo "magicctl is missing: $CTL"
  exit 1
fi

"$CTL" status
echo
echo "Use: $CTL start|stop|restart|render|check|logs|enable|disable"
