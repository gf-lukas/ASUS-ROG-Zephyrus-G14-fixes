#!/bin/bash
#
# bt-headset-mic-test.sh - measure how reliably the Bluetooth headset's
# microphone link (SCO) comes up, the way a call app triggers it.
#
# Each attempt opens a Communication-role capture stream on the default
# source for 6 s (WirePlumber's autoswitch then moves the headset to its
# headset profile), and counts it as OK when audio was captured and
# WirePlumber logged no "Failure in Bluetooth audio transport".
#
# Usage (as desktop user, no root; refuses to run while a capture stream is
# open, i.e. during a call):
#   bash configs/bluetooth/bt-headset-mic-test.sh            # 6 attempts with the installed profile (HSP or HFP)
#   bash configs/bluetooth/bt-headset-mic-test.sh -n 10      # more attempts
#   bash configs/bluetooth/bt-headset-mic-test.sh --hfp      # temporarily force HFP (+mSBC) for the test
#   bash configs/bluetooth/bt-headset-mic-test.sh --hfp-cvsd # temporarily force HFP without mSBC
#   bash configs/bluetooth/bt-headset-mic-test.sh --hsp      # temporarily force HSP for the test
#
# --hfp/--hsp drop a temporary bluetooth.lua.d file, restart WirePlumber and
# reconnect the headset, and undo all of that at the end (also on Ctrl-C).
# Use it to compare kernel or firmware changes: run --hfp before and after.

set -uo pipefail

N=6
MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) N="$2"; shift 2 ;;
        --hfp|--hfp-cvsd|--hsp) MODE="${1#--}"; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Usage: $0 [-n attempts] [--hfp|--hfp-cvsd|--hsp]" >&2; exit 2 ;;
    esac
done

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/bluetooth.lua.d"
TMP_CONF="$CONF_DIR/59-g14-mic-test.lua"
WORK=$(mktemp -d)
trap 'cleanup' EXIT INT TERM

card_info() {
    pw-dump 2>/dev/null | python3 -c '
import json,sys
for o in json.load(sys.stdin):
    pr=o.get("info",{}).get("props",{}) or {}
    if pr.get("device.api")=="bluez5" and pr.get("media.class")=="Audio/Device":
        prof=[p["name"] for p in o["info"]["params"].get("Profile",[])]
        print(pr.get("device.name",""), pr.get("api.bluez5.address",""), prof[0] if prof else "?")
        break'
}

capture_streams() {
    pw-dump 2>/dev/null | python3 -c '
import json,sys
n=0
for o in json.load(sys.stdin):
    pr=o.get("info",{}).get("props",{}) or {}
    if (pr.get("media.class") or "").startswith("Stream/Input/Audio"): n+=1
print(n)'
}

reconnect_headset() {
    local mac="$1" i
    bluetoothctl disconnect "$mac" >/dev/null 2>&1; sleep 3
    for i in 1 2 3; do
        if timeout 40 bluetoothctl connect "$mac" 2>&1 | grep -q "Connection successful"; then sleep 6; return 0; fi
        sleep 3
    done
    echo "Could not reconnect $mac" >&2; return 1
}

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/policy-bluetooth"

cleanup() {
    if [ -f "$TMP_CONF" ]; then
        echo; echo "Removing temporary profile override, restarting WirePlumber, reconnecting headset..."
        rm -f "$TMP_CONF"
        systemctl --user stop wireplumber
        # forget the headset profile remembered during the test; it may not exist with the installed roles
        sed -i -E '/^saved-headset-profile:/d' "$STATE" 2>/dev/null
        systemctl --user start wireplumber; sleep 4
        [ -n "${MAC:-}" ] && reconnect_headset "$MAC"
    fi
    rm -rf "$WORK"
}

read -r CARD MAC PROFILE < <(card_info)
if [ -z "${CARD:-}" ]; then
    echo "No Bluetooth audio card found. Connect the headset first (bluetoothctl connect <MAC>)." >&2; exit 1
fi
if [ "$(capture_streams)" != "0" ]; then
    echo "A capture stream is open (call in progress?). Refusing to run." >&2; exit 1
fi

if [ -n "$MODE" ]; then
    mkdir -p "$CONF_DIR"
    if [ "$MODE" = hfp ]; then
        printf '%s\n' '-- temporary, written by bt-headset-mic-test.sh' \
            'bluez_monitor.properties["bluez5.roles"] = "[ a2dp_sink a2dp_source hfp_ag ]"' \
            'bluez_monitor.properties["bluez5.enable-msbc"] = true' > "$TMP_CONF"
    elif [ "$MODE" = hfp-cvsd ]; then
        printf '%s\n' '-- temporary, written by bt-headset-mic-test.sh' \
            'bluez_monitor.properties["bluez5.roles"] = "[ a2dp_sink a2dp_source hfp_ag ]"' \
            'bluez_monitor.properties["bluez5.enable-msbc"] = false' > "$TMP_CONF"
    else
        printf '%s\n' '-- temporary, written by bt-headset-mic-test.sh' \
            'bluez_monitor.properties["bluez5.roles"] = "[ a2dp_sink a2dp_source hsp_ag ]"' > "$TMP_CONF"
    fi
    echo "Forcing $MODE for this test (restarting WirePlumber, reconnecting headset)..."
    systemctl --user restart wireplumber; sleep 4
    reconnect_headset "$MAC" || exit 1
fi

echo "Card: $CARD ($MAC), kernel $(uname -r), BT firmware $(journalctl -b -k --no-pager -o cat 2>/dev/null | grep -oE 'hci0: HW/SW Version.*Build Time: [0-9]+' | grep -oE '[0-9]+$' | head -1)"
echo "Running $N attempts, 6 s each..."
ok=0
for i in $(seq 1 "$N"); do
    t0=$(date +%T)
    timeout 6 pw-record -P '{ media.role = "Communication" }' "$WORK/rec_$i.wav" >/dev/null 2>&1 &
    sleep 3
    read -r _ _ prof_during < <(card_info)
    codec=$(pw-dump 2>/dev/null | python3 -c '
import json,sys
for o in json.load(sys.stdin):
    pr=o.get("info",{}).get("props",{}) or {}
    if (pr.get("node.name") or "").startswith("bluez_input."): print(pr.get("api.bluez5.codec","?")); break')
    wait
    dur=$(python3 -c "
import wave
try:
    w=wave.open('$WORK/rec_$i.wav'); print('%.1f' % (w.getnframes()/w.getframerate()))
except Exception: print('0.0')")
    fails=$(journalctl --user -u wireplumber --since "$t0" --no-pager -o cat 2>/dev/null | grep -c "Failure in Bluetooth audio transport")
    case "${prof_during:-}" in headset-head-unit*) on_headset=1 ;; *) on_headset=0 ;; esac
    if [ "$fails" = 0 ] && [ "${dur%.*}" -ge 4 ] && [ "$on_headset" = 1 ]; then ok=$((ok+1)); res=OK
    elif [ "$on_headset" = 0 ]; then res="SKIP"   # autoswitch did not move the card, capture came from another mic
    else res=FAIL; fi
    printf '  %2d/%d  %-4s profile=%-22s codec=%-6s captured=%ss transport-failures=%s\n' "$i" "$N" "$res" "${prof_during:-?}" "${codec:-?}" "$dur" "$fails"
    sleep 6
done
echo "Result: $ok of $N attempts OK (SKIP = card never left A2DP, not counted) (profile in use: ${MODE:-installed}, $(journalctl -b -k --no-pager -o cat 2>/dev/null | grep -c 'SCO packet for unknown connection handle') kernel 'SCO packet for unknown connection handle' lines this boot)"
