#!/bin/bash
# Remove hand-installed CS35L56 firmware files left behind by cirrus-fix.sh.
#
# Since linux-firmware 20240318.git3b128b60-0ubuntu3.x the package ships the
# 10431024/10431044 tuning files itself (as .bin.zst). The kernel prefers a plain
# .bin over .bin.zst in the same directory, so the old hand-copied files keep
# shadowing every future package update. They are byte-identical today, but
# remove them so dpkg owns the firmware again.
#
# Usage:
#   bash configs/cirrus/cirrus-cleanup.sh            # dry run: list what would be removed
#   sudo bash configs/cirrus/cirrus-cleanup.sh --yes # remove and refresh initramfs

set -euo pipefail

found=0
for f in /lib/firmware/cirrus/cs35l56-b0-dsp1-misc-*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ! dpkg -S "$f" >/dev/null 2>&1; then
        found=1
        if [ "${1:-}" = "--yes" ]; then
            [ "$(id -u)" -eq 0 ] || { echo "Need root: sudo bash $0 --yes" >&2; exit 1; }
            rm -v "$f"
        else
            echo "not owned by any package: $f"
        fi
    fi
done

if [ "$found" -eq 0 ]; then
    echo "Nothing to clean: every CS35L56 file in /lib/firmware/cirrus belongs to a package."
elif [ "${1:-}" = "--yes" ]; then
    update-initramfs -u
    echo "Done. Reboot, then verify:  journalctl -b -k | grep -E 'cs35l56.*(wmfw|Calibration applied)'"
else
    echo "Dry run. Re-run with:  sudo bash $0 --yes"
fi
