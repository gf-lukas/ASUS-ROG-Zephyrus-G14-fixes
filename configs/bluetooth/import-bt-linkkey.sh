#!/bin/bash
#
# import-bt-linkkey.sh - share one Bluetooth pairing between Windows and Linux
# (dual boot) by writing the link key Windows negotiated into BlueZ.
#
# Background: a classic (BR/EDR) Bluetooth device stores exactly one link key
# per adapter address. Windows and Linux share the adapter, but each pairing
# generates a fresh key, so pairing in one OS silently invalidates the other.
# Copying the key makes both OSes present the same key and the device stays
# paired in both. WirePlumber settings are keyed by the device address and are
# not affected by pairing changes.
#
# Procedure (classic headsets such as the Poly/PLT Voyager 5200):
#   1. Linux : pair the headset normally (creates the BlueZ device folder).
#   2. Windows: remove + re-pair the headset (Windows now holds the valid key).
#   3. Windows: read the key as SYSTEM (the Keys hive is not readable as admin).
#        With Sysinternals PsExec in an admin cmd:
#          psexec -s -i cmd
#          reg query "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\001122334455"
#        The line for the device (aabbccddeeff) shows a 32-hex-digit REG_BINARY.
#        Or open regedit via 'psexec -s -i regedit' and read the value there.
#   4. Linux : sudo bash configs/bluetooth/import-bt-linkkey.sh <device MAC> <32 hex digits>
#
# Usage:
#   sudo bash configs/bluetooth/import-bt-linkkey.sh --show AA:BB:CC:DD:EE:FF
#   sudo bash configs/bluetooth/import-bt-linkkey.sh AA:BB:CC:DD:EE:FF 0123456789ABCDEF0123456789ABCDEF [adapter MAC]
#
# Only the [LinkKey] section is touched; a backup of the info file is kept.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root (BlueZ state lives in /var/lib/bluetooth). Re-run with sudo." >&2
    exit 1
fi

norm_mac() { echo "$1" | tr 'a-f' 'A-F' | sed -E 's/[^0-9A-F]//g' | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/'; }

show=0
if [ "${1:-}" = "--show" ]; then show=1; shift; fi
DEV=$(norm_mac "${1:?device MAC required}")
KEY=$(echo "${2:-}" | tr 'a-f' 'A-F' | tr -d ' :-')
ADAPTER=${3:-}

if [ -z "$ADAPTER" ]; then
    mapfile -t adapters < <(find /var/lib/bluetooth -maxdepth 1 -mindepth 1 -type d -name '??:??:??:??:??:??' -printf '%f\n')
    if [ "${#adapters[@]}" -ne 1 ]; then
        echo "Found ${#adapters[@]} adapters under /var/lib/bluetooth; pass the adapter MAC as 3rd argument:" >&2
        printf '  %s\n' "${adapters[@]}" >&2; exit 1
    fi
    ADAPTER=${adapters[0]}
else
    ADAPTER=$(norm_mac "$ADAPTER")
fi

INFO="/var/lib/bluetooth/$ADAPTER/$DEV/info"
if [ ! -f "$INFO" ]; then
    echo "No pairing record at $INFO. Pair the device in Linux first (bluetoothctl)." >&2
    exit 1
fi

if [ "$show" -eq 1 ]; then
    echo "$INFO"; echo
    sed -n '/^\[General\]/,/^$/p;/^\[LinkKey\]/,/^$/p' "$INFO"
    echo "Windows registry path for this key:"
    echo "  HKLM\\SYSTEM\\CurrentControlSet\\Services\\BTHPORT\\Parameters\\Keys\\$(echo "$ADAPTER" | tr -d ':' | tr 'A-F' 'a-f')\\$(echo "$DEV" | tr -d ':' | tr 'A-F' 'a-f')"
    exit 0
fi

if ! [[ "$KEY" =~ ^[0-9A-F]{32}$ ]]; then
    echo "Key must be 32 hex digits (16 bytes), got: '${2:-}'" >&2
    exit 1
fi

cp -a "$INFO" "$INFO.bak.$(date +%Y%m%d-%H%M%S)"
if grep -q '^\[LinkKey\]' "$INFO"; then
    # replace Key= inside the [LinkKey] section only
    awk -v key="$KEY" '
        /^\[/ { insec = ($0 == "[LinkKey]") }
        insec && /^Key=/ { print "Key=" key; done=1; next }
        { print }
        END { if (!done) exit 3 }' "$INFO" > "$INFO.new" || { echo "[LinkKey] section has no Key= line; refusing to guess." >&2; rm -f "$INFO.new"; exit 1; }
    mv "$INFO.new" "$INFO"
else
    printf '\n[LinkKey]\nKey=%s\nType=4\nPINLength=0\n' "$KEY" >> "$INFO"
fi
chmod 600 "$INFO"
echo "Updated $INFO:"; sed -n '/^\[LinkKey\]/,/^$/p' "$INFO"
echo "Restarting bluetooth.service so bluetoothd reloads the key..."
systemctl restart bluetooth
echo "Done. Power-cycle the headset; it should reconnect without re-pairing."
