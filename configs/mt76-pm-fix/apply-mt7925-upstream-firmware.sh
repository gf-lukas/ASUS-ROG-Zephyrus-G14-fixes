#!/bin/bash
#
# mt7925-fw-update.sh - pin a recent MediaTek MT7925 (Wi-Fi 7 + Bluetooth)
# firmware from upstream linux-firmware on Ubuntu 24.04.
#
# The kernel loads firmware from /lib/firmware/updates/ BEFORE /lib/firmware/,
# so a manual override there silently masks newer blobs from later
# linux-firmware package updates. This script keeps that override pinned to a
# known upstream tag, verifies checksums, and can remove it again.
#
# Usage:
#   bash configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh --check        # show loaded / packaged / override builds
#   sudo bash configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh           # install override from tag ${FW_TAG}
#   sudo bash configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh --revert  # remove override, fall back to the distro package
#
# Reboot after install or revert (Wi-Fi and Bluetooth firmware load at boot).

set -euo pipefail

FW_TAG="${FW_TAG:-20260916}"
BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925"
OVERRIDE_DIR=/lib/firmware/updates/mediatek/mt7925
DISTRO_DIR=/lib/firmware/mediatek/mt7925

# file  sha256 (linux-firmware tag 20260916, firmware build 2026-08-13)
FILES="
WIFI_RAM_CODE_MT7925_1_1.bin      23ff53b4bb639b30481e2e06bb1688569ad1ba971b897936db539882abfbd120
WIFI_MT7925_PATCH_MCU_1_1_hdr.bin 8eb46014d2a6b4124472eee7476d995008a6f40b1daffef87eb42f30d98699e1
BT_RAM_CODE_MT7925_1_1_hdr.bin    be7c18e37221e277baaef853be3a0ba930138ee879f336ff7b185e79ab09a5c9
"

# Print the build timestamp embedded in a MediaTek blob (plain or .zst).
fw_build() {
    local f="$1" out
    # subshell without pipefail: grep -m1 closing the pipe early is not an error
    if [ -r "$f" ]; then
        out=$(set +o pipefail; strings "$f" | grep -m1 -oE '20[0-9]{12}')
    elif [ -r "$f.zst" ]; then
        out=$(set +o pipefail; zstd -dc "$f.zst" | strings | grep -m1 -oE '20[0-9]{12}')
    else
        out="n/a"
    fi
    echo "${out:-unknown}"
}

check() {
    echo "Wi-Fi loaded by kernel   : $(journalctl -b -k --no-pager 2>/dev/null | grep -oE 'mt7925e.*WM Firmware Version.*Build Time: [0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
    echo "Bluetooth loaded by kernel: $(journalctl -b -k --no-pager 2>/dev/null | grep -oE 'hci0: HW/SW Version.*Build Time: [0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
    printf '%-34s %-16s %-16s\n' "file" "distro package" "override"
    echo "$FILES" | while read -r name sha; do
        [ -n "$name" ] || continue
        printf '%-34s %-16s %-16s\n' "$name" "$(fw_build "$DISTRO_DIR/$name")" "$(fw_build "$OVERRIDE_DIR/$name")"
    done
    echo "Pinned upstream tag      : ${FW_TAG} (build 20260813)"
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This action needs root. Re-run with: sudo $0 $*" >&2
        exit 1
    fi
}

case "${1:-}" in
    --check)
        check
        ;;
    --revert)
        need_root --revert
        if [ -d "$OVERRIDE_DIR" ]; then
            rm -rfv "$OVERRIDE_DIR"
            rmdir /lib/firmware/updates/mediatek 2>/dev/null || true
            update-initramfs -u
            echo "Override removed. Reboot to load the distro package firmware."
        else
            echo "No override at $OVERRIDE_DIR - nothing to do."
        fi
        ;;
    "")
        need_root
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        echo "$FILES" | while read -r name sha; do
            [ -n "$name" ] || continue
            echo "Downloading $name (tag ${FW_TAG}) ..."
            curl -fsSL -o "$tmp/$name" "${BASE_URL}/${name}?h=${FW_TAG}"
            echo "$sha  $tmp/$name" | sha256sum -c -
        done
        install -d -m 755 "$OVERRIDE_DIR"
        # Replace the whole set so Wi-Fi patch/RAM and BT blobs always match.
        rm -f "$OVERRIDE_DIR"/*.bin "$OVERRIDE_DIR"/.source-*
        install -m 644 -o root -g root "$tmp"/*.bin "$OVERRIDE_DIR/"
        echo "source=linux-firmware.git tag=${FW_TAG} installed=$(date -I) by=$(basename "$0")" > "$OVERRIDE_DIR/.source-linux-firmware-${FW_TAG}"
        update-initramfs -u
        echo
        check
        echo
        echo "Done. Reboot, then verify with:  $0 --check  (loaded builds should read 20260813...)"
        ;;
    *)
        echo "Usage: $0 [--check|--revert]" >&2
        exit 2
        ;;
esac
