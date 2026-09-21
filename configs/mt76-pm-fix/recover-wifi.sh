#!/bin/bash
# Fast Wi-Fi recovery helper for MT7925 instability
# Modes:
#   --reconnect-only   : NetworkManager disconnect/connect
#   --full-reload      : reconnect + reload mt7925 stack (requires sudo)

set -euo pipefail

IFACE="${WIFI_IFACE:-wlp99s0}"
MODE="reconnect-only"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconnect-only)
      MODE="reconnect-only"
      shift
      ;;
    --full-reload)
      MODE="full-reload"
      shift
      ;;
    --iface)
      IFACE="${2:-$IFACE}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--reconnect-only|--full-reload] [--iface <name>]" >&2
      exit 2
      ;;
  esac
done

echo "[+] Using interface: $IFACE"
echo "[+] Reconnecting via NetworkManager"
nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
sleep 1
nmcli device connect "$IFACE" >/dev/null

if command -v iw >/dev/null 2>&1; then
  echo "[+] Forcing 802.11 powersave off on $IFACE"
  iw dev "$IFACE" set power_save off >/dev/null 2>&1 || true
fi

if [[ "$MODE" == "full-reload" ]]; then
  echo "[+] Reloading MT7925 modules (sudo required)"
  sudo modprobe -r mt7925e mt7925_common mt792x_lib mt76_connac_lib mt76 || true
  sleep 1
  sudo modprobe mt7925e || true
  sleep 1
  nmcli device connect "$IFACE" >/dev/null 2>&1 || true
fi

echo "[+] Done"
iw dev "$IFACE" link 2>/dev/null || true
iw dev "$IFACE" get power_save 2>/dev/null || true
