#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root" >&2
  exit 1
fi

log() {
  printf '%s [g14-gpu-boot-mode] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

CONFIG_FILE="/etc/supergfxd.conf"

get_power_source() {
  local ac
  for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online /sys/class/power_supply/ACAD/online; do
    if [[ -f "$ac" ]]; then
      if [[ "$(cat "$ac")" == "1" ]]; then
        echo "ac"
      else
        echo "dc"
      fi
      return
    fi
  done

  echo "dc"
}

update_supergfxd_mode() {
  local target_mode="$1"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Missing $CONFIG_FILE; skipping"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 not found; skipping"
    return 0
  fi

  if python3 - "$CONFIG_FILE" "$target_mode" <<'PY'
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]

with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

if data.get('mode') == mode:
    print('unchanged')
    sys.exit(0)

data['mode'] = mode

with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print('updated')
PY
  then
    return 0
  fi

  log "Failed to update mode in $CONFIG_FILE"
  return 1
}

source="$(get_power_source)"
if [[ "$source" == "dc" ]]; then
  target_mode="Integrated"
else
  target_mode="Hybrid"
fi

if update_supergfxd_mode "$target_mode"; then
  log "Configured supergfxd mode '$target_mode' for source=$source"
else
  log "Could not configure supergfxd mode '$target_mode'"
fi
