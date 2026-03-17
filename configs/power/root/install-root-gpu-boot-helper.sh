#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash configs/power/root/install-root-gpu-boot-helper.sh" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER_SRC="$ROOT_DIR/configs/power/root/g14-gpu-boot-mode.sh"
HELPER_DST="/usr/local/bin/g14-gpu-boot-mode.sh"
SERVICE_SRC="$ROOT_DIR/configs/power/systemd-system/g14-gpu-boot-mode.service"
SERVICE_DST="/etc/systemd/system/g14-gpu-boot-mode.service"

install -m 755 "$HELPER_SRC" "$HELPER_DST"
install -m 644 "$SERVICE_SRC" "$SERVICE_DST"

systemctl daemon-reload
systemctl reenable g14-gpu-boot-mode.service

echo "Installed $HELPER_DST"
echo "Installed and enabled $SERVICE_DST"
echo "GPU boot policy: battery -> Integrated, AC -> Hybrid"
echo "Service will apply before supergfxd on next boot"
