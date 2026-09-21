#!/bin/bash
#
# install-bt-headset-autoswitch.sh - make WirePlumber 0.4 switch a Bluetooth
# headset to HSP/HFP (microphone) for calls even when the default output is
# something else (HDMI monitor, speakers).
#
# Stock WirePlumber 0.4.17 only switches when the headset is the *default sink*.
# The override in wireplumber/policy-bluetooth.lua also switches when the
# headset is the configured default *source* (chosen as input device in GNOME
# Settings > Sound), and refuses to "switch" to a remembered profile without a
# microphone. See the header of that file for details.
#
# Usage (as desktop user, no root):
#   bash configs/bluetooth/install-bt-headset-autoswitch.sh           # install + restart WirePlumber
#   bash configs/bluetooth/install-bt-headset-autoswitch.sh --check   # show state
#   bash configs/bluetooth/install-bt-headset-autoswitch.sh --revert  # remove override + restart WirePlumber
#
# Restarting WirePlumber briefly interrupts audio (about one second).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$HERE/wireplumber/policy-bluetooth.lua"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/scripts"
DEST="$DEST_DIR/policy-bluetooth.lua"
STOCK=/usr/share/wireplumber/scripts/policy-bluetooth.lua
# stock script the override was derived from (WirePlumber 0.4.17)
STOCK_SHA=8fe690b14f01e677445f190a32a631d5a5fda6f157e683e0ebf7e80515ab20fa
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/policy-bluetooth"

wp_version() { wireplumber --version 2>/dev/null | awk '/^Compiled with/ {print $NF; exit}'; }

check_compat() {
    local v; v=$(wp_version || true)
    case "$v" in
        0.4.*) ;;
        "")   echo "WARNING: wireplumber binary not found; cannot verify version." >&2 ;;
        *)    echo "ERROR: WirePlumber $v uses a different (non-Lua-0.4) policy layout; this override is for 0.4.x only." >&2
              return 1 ;;
    esac
    if [ -r "$STOCK" ] && [ "$(sha256sum "$STOCK" | cut -d' ' -f1)" != "$STOCK_SHA" ]; then
        echo "WARNING: stock $STOCK differs from the version this override was derived from." >&2
        echo "         Compare with 'diff -u $STOCK $SRC' before trusting it." >&2
    fi
}

check() {
    echo "WirePlumber version : $(wp_version || echo unknown)"
    if [ -f "$DEST" ]; then
        if cmp -s "$SRC" "$DEST"; then echo "Override installed   : yes ($DEST, matches repo)"
        else echo "Override installed   : yes ($DEST, DIFFERS from repo copy)"; fi
    else
        echo "Override installed   : no"
    fi
    echo "Stock script sha256 : $( [ -r "$STOCK" ] && sha256sum "$STOCK" | cut -d' ' -f1 || echo n/a ) (expected $STOCK_SHA)"
    echo "Saved headset profile: $(grep -E '^saved-headset-profile' "$STATE" 2>/dev/null || echo '(none)')"
    echo "Configured default source: $(pw-metadata 0 default.configured.audio.source 2>/dev/null | grep -oE 'bluez_input[^"]*|alsa_input[^"]*' || echo unknown)"
    echo "Bluetooth cards:"
    pw-dump 2>/dev/null | python3 -c '
import json,sys
for o in json.load(sys.stdin):
    pr=o.get("info",{}).get("props",{}) or {}
    if pr.get("device.api")=="bluez5" and pr.get("media.class")=="Audio/Device":
        prof=[x["name"] for x in o["info"]["params"].get("Profile",[])]
        print("  %-40s profile=%s" % (pr.get("device.description"), ",".join(prof) or "?"))' 2>/dev/null || echo "  (pw-dump unavailable)"
}

restart_wp() {
    echo "Restarting WirePlumber (short audio interruption)..."
    systemctl --user restart wireplumber
    sleep 2
    systemctl --user is-active --quiet wireplumber && echo "WirePlumber active." || { echo "WirePlumber failed to start, see: journalctl --user -u wireplumber" >&2; exit 1; }
}

case "${1:-}" in
    --check)
        check ;;
    --revert)
        if [ -f "$DEST" ]; then rm -v "$DEST"; rmdir --ignore-fail-on-non-empty "$DEST_DIR" 2>/dev/null || true
        else echo "Nothing to revert: $DEST not present."; fi
        restart_wp ;;
    "")
        check_compat
        install -D -m 0644 "$SRC" "$DEST"
        echo "Installed $DEST"
        # Drop a remembered mic-less "headset profile" so the first call works.
        if grep -qE '^saved-headset-profile:.*=a2dp-' "$STATE" 2>/dev/null; then
            echo "Removing remembered A2DP 'headset profile' from $STATE"
            systemctl --user stop wireplumber
            sed -i '/^saved-headset-profile:.*=a2dp-/d' "$STATE"
        fi
        restart_wp
        echo
        echo "Done. Select the headset as INPUT device once (GNOME Settings > Sound > Input);"
        echo "calls in Firefox/Chrome/Teams then switch it to the headset profile automatically,"
        echo "regardless of which output device is selected." ;;
    *)
        echo "Usage: $0 [--check|--revert]" >&2; exit 2 ;;
esac
