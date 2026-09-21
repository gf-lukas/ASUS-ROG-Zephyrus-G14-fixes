#!/bin/bash
#
# amdgpu-dmub-fix.sh - pin a known-good AMD DMUB (display microcontroller)
# firmware for DCN 3.5 iGPUs (Strix Point, PCI 1002:150e) on Ubuntu 24.04.
#
# Background: linux-firmware 20240318.git3b128b60-0ubuntu3.x (Sep 2026) split
# the package into linux-firmware-amd-graphics and shipped an OLD
# dcn_3_5_dmcub.bin (DMUB 0x09000D00, upstream tag 20241210). The previous
# 0ubuntu2.27 package shipped DMUB 0x09002C01 (upstream tag 20250917). With the
# old blob the machine hard-freezes at random with:
#   amdgpu 0000:65:00.0: [drm] *ERROR* [CRTC:417:crtc-0] hw_done or flip_done timed out
#
# This script drops the good blob into /lib/firmware/updates/amdgpu/, which the
# kernel firmware loader searches BEFORE /lib/firmware/. It survives package
# upgrades and can be removed with --revert.
#
# Usage:
#   sudo bash configs/amdgpu/amdgpu-dmub-fix.sh            # install override
#   sudo bash configs/amdgpu/amdgpu-dmub-fix.sh --revert   # remove override
#   bash configs/amdgpu/amdgpu-dmub-fix.sh --check         # show DMUB versions (no root needed)
#
# Override the blob name for other DCN 3.5 variants, e.g. Krackan Point:
#   FW_NAME=dcn_3_5_1_dmcub.bin FW_SHA256=<sha> sudo -E bash configs/amdgpu/amdgpu-dmub-fix.sh

set -euo pipefail

FW_NAME="${FW_NAME:-dcn_3_5_dmcub.bin}"
FW_TAG="${FW_TAG:-20250917}"
FW_SHA256="${FW_SHA256:-ce5dc8ef543ce71a0ef772d4d821872fbfaa48afd0634e00f814e04ed991c431}"
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu/${FW_NAME}?h=${FW_TAG}"

OVERRIDE_DIR=/lib/firmware/updates/amdgpu
OVERRIDE="${OVERRIDE_DIR}/${FW_NAME}"
DISTRO_ZST="/lib/firmware/amdgpu/${FW_NAME}.zst"

# Print the fw_version embedded in a DMUB blob (plain or .zst).
dmub_version() {
    local f="$1"
    [ -r "$f" ] || { echo "n/a"; return; }
    python3 - "$f" <<'PY'
import struct, subprocess, sys
f = sys.argv[1]
data = subprocess.run(["zstd", "-dc", f], capture_output=True).stdout if f.endswith(".zst") else open(f, "rb").read()
i = data.find(b"BUMD")  # DMUB_FW_META_MAGIC, little-endian
print("0x%08X" % struct.unpack_from("<I", data, i + 12)[0] if i >= 0 else "unknown")
PY
}

check() {
    echo "Loaded by running kernel : $(journalctl -b -k --no-pager 2>/dev/null | grep -oE 'DMUB hardware initialized: version=0x[0-9A-Fa-f]+' | head -1 | sed 's/.*version=//' || true)"
    echo "Distro package blob      : ${DISTRO_ZST} -> $(dmub_version "$DISTRO_ZST")"
    echo "Override blob            : ${OVERRIDE} -> $(dmub_version "$OVERRIDE")"
    echo "Known-good version       : 0x09002C01 (upstream tag ${FW_TAG})"
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
        if [ -e "$OVERRIDE" ]; then
            rm -v "$OVERRIDE"
            rmdir "$OVERRIDE_DIR" 2>/dev/null || true
            update-initramfs -u
            echo "Override removed. Reboot to go back to the distro firmware."
        else
            echo "No override installed at $OVERRIDE - nothing to do."
        fi
        ;;
    "")
        need_root
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        echo "Downloading ${FW_NAME} (linux-firmware tag ${FW_TAG}) ..."
        curl -fsSL -o "${tmp}/${FW_NAME}" "$FW_URL"
        echo "${FW_SHA256}  ${tmp}/${FW_NAME}" | sha256sum -c -
        echo "Downloaded DMUB version: $(dmub_version "${tmp}/${FW_NAME}")"
        install -d -m 755 "$OVERRIDE_DIR"
        install -m 644 -o root -g root "${tmp}/${FW_NAME}" "$OVERRIDE"
        update-initramfs -u
        echo
        check
        echo
        echo "Done. Reboot, then verify with:  $0 --check"
        echo "(the 'Loaded by running kernel' line should show 0x09002C01)"
        ;;
    *)
        echo "Usage: $0 [--check|--revert]" >&2
        exit 2
        ;;
esac
