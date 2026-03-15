#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root" >&2
  exit 1
fi

mode="${1:-}"
CPU_BOOST_PATH="/sys/devices/system/cpu/cpufreq/boost"

set_boost() {
  local value="$1"
  [[ -w "$CPU_BOOST_PATH" ]] || return 0
  printf '%s\n' "$value" > "$CPU_BOOST_PATH"
}

set_epp() {
  local desired="$1"
  local file
  shopt -s nullglob
  for file in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
    [[ -w "$file" ]] || continue
    printf '%s\n' "$desired" > "$file" || true
  done
  shopt -u nullglob
}

set_governor() {
  local desired="$1"
  local file avail
  shopt -s nullglob
  for file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [[ -w "$file" ]] || continue
    avail="$(cat "${file%/*}/scaling_available_governors" 2>/dev/null || true)"
    if [[ -n "$avail" && ! " $avail " =~ [[:space:]]${desired}[[:space:]] ]]; then
      continue
    fi
    printf '%s\n' "$desired" > "$file" || true
  done
  shopt -u nullglob
}

case "$mode" in
  power-saver)
    set_boost "0"
    set_epp "power"
    set_governor "powersave"
    ;;
  balanced)
    set_boost "1"
    set_epp "balance_power"
    set_governor "powersave"
    ;;
  performance)
    set_boost "1"
    set_epp "performance"
    set_governor "performance"
    ;;
  *)
    echo "Usage: $0 {power-saver|balanced|performance}" >&2
    exit 2
    ;;
esac
