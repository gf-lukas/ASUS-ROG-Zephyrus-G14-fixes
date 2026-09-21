#!/bin/bash
# Reports whether the NVIDIA dGPU is really asleep (runtime D3) and what keeps it awake.
# Read-only and deliberately avoids nvidia-smi, which would wake the GPU.
#
#   bash g14-dgpu-sleep-check.sh            one snapshot
#   bash g14-dgpu-sleep-check.sh --watch    snapshot every 5 s (Ctrl-C to stop)
set -uo pipefail

find_bdf() {
  local dev
  for dev in /sys/bus/pci/devices/*; do
    [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x10de" && "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] && { basename "$dev"; return; }
  done
}

battery_watts() {
  local b p c v
  for b in /sys/class/power_supply/BAT*; do
    [[ -d "$b" ]] || continue
    if [[ -r "$b/power_now" ]]; then
      p="$(cat "$b/power_now")"; awk -v p="$p" 'BEGIN{printf "%.1f", p/1e6}'; return
    fi
    if [[ -r "$b/current_now" && -r "$b/voltage_now" ]]; then
      c="$(cat "$b/current_now")"; v="$(cat "$b/voltage_now")"
      awk -v c="$c" -v v="$v" 'BEGIN{printf "%.1f", c*v/1e12}'; return
    fi
  done
  echo "n/a"
}

snapshot() {
  local bdf dev mode drv card
  mode="$(timeout 5 supergfxctl -g 2>/dev/null || echo unknown)"
  bdf="$(find_bdf)"
  echo "time:            $(date '+%H:%M:%S')"
  echo "supergfx mode:   $mode"
  echo "ac online:       $(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1)"
  echo "battery:         $(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1), draw $(battery_watts) W"
  if [[ -z "$bdf" ]]; then
    echo "dgpu:            not on the PCI bus (Integrated mode)"
    return
  fi
  dev="/sys/bus/pci/devices/$bdf"
  drv="$(basename "$(readlink "$dev/driver" 2>/dev/null || echo none)")"
  echo "dgpu:            $bdf driver=$drv"
  echo "runtime pm:      control=$(cat "$dev/power/control" 2>/dev/null) status=$(cat "$dev/power/runtime_status" 2>/dev/null) power_state=$(cat "$dev/power_state" 2>/dev/null)"
  echo "suspended for:   $(( $(cat "$dev/power/runtime_suspended_time" 2>/dev/null || echo 0) / 1000 )) s total, active $(( $(cat "$dev/power/runtime_active_time" 2>/dev/null || echo 0) / 1000 )) s total"
  if [[ -r /proc/driver/nvidia/gpus/$bdf/power ]]; then
    grep -E "Runtime D3|Video Memory" "/proc/driver/nvidia/gpus/$bdf/power" | sed 's/^/nvidia:          /'
  fi
  for card in /sys/class/drm/card[0-9]; do
    [[ "$(readlink -f "$card/device")" == "$(readlink -f "$dev")" ]] || continue
    for c in "$card"-*/status; do
      [[ "$(cat "$c")" == "connected" ]] && echo "dgpu output:     $(basename "$(dirname "$c")") connected (keeps dGPU awake)"
    done
  done
  local holders
  holders="$(fuser -v /dev/nvidia* 2>&1 | awk 'NR>1 && $NF!="" {print $NF}' | sort -u | tr '\n' ' ')"
  echo "holders:         ${holders:-none} (open /dev/nvidia*; GNOME Shell alone is normal)"
}

if [[ "${1:-}" == "--watch" ]]; then
  while true; do snapshot; echo; sleep 5; done
else
  snapshot
fi
