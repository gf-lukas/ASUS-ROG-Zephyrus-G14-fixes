#!/bin/bash
# Configure GNOME Vitals extension for Zephyrus G14 telemetry
# Sets panel sensors to: CPU %, GPU % (if the power-safe wrapper is installed), RAM %, Battery power (W)
# Fixes "Battery: no data" by selecting BAT1 (this laptop uses BAT1, not BAT0/BATT).
#
# GPU sensors are enabled only when the power-safe nvidia-smi wrapper is installed
# (sudo bash configs/gnome/install-nvidia-smi-powersafe.sh). With the stock nvidia-smi, Vitals keeps an
# `nvidia-smi -l 1` subprocess running for the whole session; that query every second never lets the
# RTX 5070 Ti reach runtime D3, so in Hybrid mode the dGPU stays in D0 and costs ~8 W on battery
# (measured 2026-09-21: 18-20 W idle with polling, 10 W without). The wrapper prints N/A while the dGPU
# is asleep or unused and only queries the real nvidia-smi while a client (RL job, offloaded app) holds it.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

command -v gnome-extensions >/dev/null || err "gnome-extensions not found (install GNOME Shell integration tools)"
command -v dconf >/dev/null || err "dconf not found"

EXT_ID="Vitals@CoreCoding.com"

if ! gnome-extensions info "$EXT_ID" >/dev/null 2>&1; then
    err "Vitals extension is not installed. Install it from https://extensions.gnome.org/extension/1460/vitals/"
fi

if ! gnome-extensions info "$EXT_ID" | grep -q "Enabled: Yes"; then
    warn "Vitals is installed but disabled; enabling now"
    gnome-extensions enable "$EXT_ID" || true
fi

log "Detecting battery name in /sys/class/power_supply..."
battery_name=""
for candidate in BAT1 BAT0 BAT2 BATT CMB0 CMB1 CMB2 macsmc-battery; do
    if [[ -e "/sys/class/power_supply/${candidate}/uevent" ]]; then
        battery_name="$candidate"
        break
    fi
done

if [[ -z "$battery_name" ]]; then
    warn "No known battery path found; keeping current battery-slot setting"
else
    # Vitals slot mapping from prefs.ui
    # 0: BAT0, 1: BAT1, 2: BAT2, 3: BATT, 4: CMB0, 5: CMB1, 6: CMB2, 7: macsmc-battery
    case "$battery_name" in
        BAT0) battery_slot=0 ;;
        BAT1) battery_slot=1 ;;
        BAT2) battery_slot=2 ;;
        BATT) battery_slot=3 ;;
        CMB0) battery_slot=4 ;;
        CMB1) battery_slot=5 ;;
        CMB2) battery_slot=6 ;;
        macsmc-battery) battery_slot=7 ;;
        *) battery_slot=1 ;;
    esac

    log "Setting Vitals battery-slot to ${battery_slot} (${battery_name})"
    dconf write /org/gnome/shell/extensions/vitals/battery-slot "$battery_slot"
fi

WRAPPER="/usr/local/bin/nvidia-smi"
gpu_enabled=false
if [[ -x "$WRAPPER" ]] && grep -q "nvidia-smi-powersafe" "$WRAPPER"; then
    gpu_enabled=true
    log "Power-safe nvidia-smi wrapper found; enabling GPU sensors"
    # Make Vitals render N/A (instead of the last value) for fields the wrapper reports as unavailable
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/vitals-na-patch.sh"; then
        warn "Vitals N/A patch could not be applied; GPU % will read 0 while the dGPU sleeps"
    fi
else
    warn "Power-safe nvidia-smi wrapper not installed; GPU sensors stay OFF (they would keep the dGPU awake)"
    warn "Install it with: sudo bash $(dirname "${BASH_SOURCE[0]}")/install-nvidia-smi-powersafe.sh, then rerun this script"
fi

log "Enabling required sensor groups"
dconf write /org/gnome/shell/extensions/vitals/show-processor true
dconf write /org/gnome/shell/extensions/vitals/show-gpu "$gpu_enabled"
dconf write /org/gnome/shell/extensions/vitals/show-memory true
dconf write /org/gnome/shell/extensions/vitals/show-battery true

if [[ "$gpu_enabled" == "true" ]]; then
    # Vitals indexes nvidia-smi GPUs as gpu#1..N
    log "Setting panel hot sensors: CPU %, GPU %, RAM %, Battery power"
    dconf write /org/gnome/shell/extensions/vitals/hot-sensors "['_processor_usage_', '_gpu#1_utilization_', '_memory_usage_', '_battery_power_rate_']"
else
    log "Setting panel hot sensors: CPU %, RAM %, Battery power"
    dconf write /org/gnome/shell/extensions/vitals/hot-sensors "['_processor_usage_', '_memory_usage_', '_battery_power_rate_']"
fi

log "Reloading Vitals extension"
gnome-extensions disable "$EXT_ID" || true
gnome-extensions enable "$EXT_ID"

echo ""
log "Vitals configuration applied"
echo "  battery-slot : $(dconf read /org/gnome/shell/extensions/vitals/battery-slot 2>/dev/null || echo unknown)"
echo "  hot-sensors  : $(dconf read /org/gnome/shell/extensions/vitals/hot-sensors 2>/dev/null || echo unknown)"

echo ""
if [[ "$gpu_enabled" == "true" ]]; then
    echo "GPU % shows N/A while the dGPU is asleep or unused; values appear as soon as a job holds the GPU."
    echo "If the N/A patch was applied just now, log out and back in once: GNOME Shell loads extension code per session."
else
    echo "GPU sensors are disabled: Vitals' stock nvidia-smi polling keeps the dGPU awake (~8 W on battery)."
fi
echo "Check dGPU sleep with: bash configs/power/g14-dgpu-sleep-check.sh"
echo "Battery wattage sign is inferred from State (Charging/Discharging)."
