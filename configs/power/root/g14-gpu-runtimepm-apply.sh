#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root" >&2
  exit 1
fi

changed="no"

for dev in /sys/bus/pci/devices/*; do
  [[ -f "$dev/vendor" && -f "$dev/class" ]] || continue

  vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
  class="$(cat "$dev/class" 2>/dev/null || true)"

  # Target NVIDIA VGA/3D and HDMI-audio functions only.
  if [[ "$vendor" != "0x10de" ]]; then
    continue
  fi
  if [[ "$class" != 0x03* && "$class" != 0x04* ]]; then
    continue
  fi

  ctrl="$dev/power/control"
  [[ -w "$ctrl" ]] || continue

  current="$(cat "$ctrl" 2>/dev/null || true)"
  if [[ "$current" != "auto" ]]; then
    printf '%s\n' auto > "$ctrl"
    changed="yes"
  fi
done

if [[ "$changed" == "yes" ]]; then
  echo "Set NVIDIA runtime PM control to auto"
else
  echo "NVIDIA runtime PM control already auto or not writable"
fi
