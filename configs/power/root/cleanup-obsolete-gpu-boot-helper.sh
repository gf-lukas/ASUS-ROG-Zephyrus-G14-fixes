#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash configs/power/root/cleanup-obsolete-gpu-boot-helper.sh" >&2
  exit 1
fi

SERVICE_NAME="g14-gpu-boot-mode.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
HELPER_FILE="/usr/local/bin/g14-gpu-boot-mode.sh"
SUPERGFX_CONF="/etc/supergfxd.conf"

changed="no"

if systemctl list-unit-files | awk '{print $1}' | grep -qx "$SERVICE_NAME"; then
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  changed="yes"
fi

if [[ -e "$SERVICE_FILE" ]]; then
  rm -f "$SERVICE_FILE"
  changed="yes"
fi

if [[ -e "$HELPER_FILE" ]]; then
  rm -f "$HELPER_FILE"
  changed="yes"
fi

if [[ -f "$SUPERGFX_CONF" ]] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$SUPERGFX_CONF" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

if data.get('mode') == 'Hybrid':
    print('mode-unchanged')
    sys.exit(0)

data['mode'] = 'Hybrid'
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print('mode-updated')
PY
  then
    changed="yes"
  fi
fi

systemctl daemon-reload

echo "Removed obsolete boot GPU helper artifacts (if present)."
echo "Set /etc/supergfxd.conf mode to Hybrid (if writable)."
if [[ "$changed" == "yes" ]]; then
  echo "A reboot is recommended to fully recover supergfxd if it is currently stuck."
else
  echo "No changes were required."
fi
