#!/bin/bash
# Apply persistent MT7925 ASPM-off workaround on Ubuntu
# - Writes modprobe option: options mt7925e disable_aspm=Y
# - Forces NetworkManager WiFi powersave off
# - Forces mt7925e PCI runtime PM to "on"
# - Regenerates initramfs

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo bash configs/mt76-pm-fix/apply-mt7925-aspm-off.sh"

CONF_FILE="/etc/modprobe.d/mt7925e-aspm-off.conf"
NM_CONF_FILE="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
UDEV_RULE_FILE="/etc/udev/rules.d/80-mt7925e-runtime-pm-off.rules"

if ! modinfo mt7925e >/dev/null 2>&1; then
  warn "mt7925e module not found in current kernel. Continuing to write config anyway."
fi

log "Writing modprobe config: $CONF_FILE"
cat > "$CONF_FILE" <<'EOF'
options mt7925e disable_aspm=Y
EOF

log "Writing NetworkManager WiFi powersave policy: $NM_CONF_FILE"
cat > "$NM_CONF_FILE" <<'EOF'
[connection]
wifi.powersave = 2
EOF

log "Writing udev rule to keep mt7925e runtime PM disabled: $UDEV_RULE_FILE"
cat > "$UDEV_RULE_FILE" <<'EOF'
ACTION=="add|change", SUBSYSTEM=="pci", DRIVERS=="mt7925e", TEST=="power/control", ATTR{power/control}="on"
EOF

log "Reloading udev rules"
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=pci || true

if [[ -d /sys/bus/pci/drivers/mt7925e ]]; then
  for dev in /sys/bus/pci/drivers/mt7925e/*:*; do
    [[ -e "$dev/power/control" ]] || continue
    printf 'on\n' > "$dev/power/control" || true
  done
fi

log "Restarting NetworkManager"
systemctl restart NetworkManager || true

log "Refreshing initramfs"
update-initramfs -u

echo ""
log "Done"
echo "Next steps:"
echo "  1) Reboot"
echo "  2) Verify after reboot: cat /sys/module/mt7925e/parameters/disable_aspm"
echo "  3) Verify runtime PM: for d in /sys/bus/pci/drivers/mt7925e/*:*; do cat \"$d/power/control\"; done"
