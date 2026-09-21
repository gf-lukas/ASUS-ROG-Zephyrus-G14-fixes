# FIXED: Hard freeze from AMD DMCUB firmware downgrade (2026-09-14)

**Status:** fixed 2026-09-20 with [`configs/amdgpu/amdgpu-dmub-fix.sh`](../configs/amdgpu/amdgpu-dmub-fix.sh);
verified after reboot: `DMUB hardware initialized: version=0x09002C01`. A third freeze
(2026-09-20 17:30, same signature, ~26h uptime) happened before the fix was applied.

## Symptom

Total system freeze — display frozen, input dead, no SSH, no VT switch. Only
recovery is a 4-second power button hold. Two occurrences within 12 minutes:

- `22:29:31` — after ~2h55m uptime
- `22:41:36` — ~36s after login, while X was bringing up both GPUs

Journal ends mid-line in both cases with no shutdown sequence.

## Root cause

The `18:23` update on 2026-09-14 **downgraded** the DMCUB (display
microcontroller) firmware for the Radeon 890M iGPU:

| Boot | DMCUB version | Outcome |
|---|---|---|
| before update | `0x09002C01` = **9.0.44.1** | clean shutdowns |
| after update | `0x09000D00` = **9.0.13.0** | **hard freeze, twice** |

Diffing the full `amdgpu` bring-up between a stable pre-update boot and a
crashing post-update boot gives **exactly two differing lines out of 81** —
both the DMCUB version. Nothing else in the GPU init changed.

Kernel is not implicated: `7.0.0-31-generic` ran from Sep 10 across many
clean boots on the old firmware.

### Failure signature

```
amdgpu 0000:65:00.0: [drm] *ERROR* [CRTC:417:crtc-0] hw_done or flip_done timed out
gnome-shell: Could not release device '/dev/input/event6' (13,70): Timeout was reached
```

DMCUB drives the display engine. When it wedges, the CRTC never signals flip
completion, the compositor blocks forever on vblank, and input handling dies
with it — an unkillable freeze rather than a recoverable GPU reset.

### How the downgrade happened

Ubuntu split monolithic `linux-firmware` into per-vendor packages. This box
went `linux-firmware 2.27` → the split `-0ubuntu3.x` set, branched from an
older firmware snapshot. Note `linux-firmware-amd-graphics` shipped at
`-0ubuntu3.2` while every sibling package is `3.1`; that `3.2` respin reverts
an *unrelated* DMCUB regression (Navi 21 black screens, LP #2163303). In doing
so it carries a DCN 3.5 blob older than what was already installed.

Affected file: `/lib/firmware/amdgpu/dcn_3_5_dmcub.bin.zst`
(DCN 3.5.0 = Strix Point / gfx1150 = Radeon 890M)

## Planned fix — restore DMCUB 9.0.44.1

`apt` cannot fix this: the archive only offers `-0ubuntu3.2` (the broken
version), and the local apt cache holds no `2.27` copy.

Use the same override mechanism as
[`configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh`](../configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh)
— the kernel firmware loader prefers `/lib/firmware/updates` over
`/lib/firmware`, so this survives package updates and does not fight dpkg:

1. Pull `linux-firmware_20240318.git3b128b60-0ubuntu2.27` from Launchpad
   (or take `dcn_3_5_dmcub.bin` from upstream `linux-firmware.git` — confirm
   it reports `9.0.44.1` or newer, **not** 9.0.13.0).
2. Install to `/lib/firmware/updates/amdgpu/dcn_3_5_dmcub.bin`.
3. `update-initramfs -u`, reboot.
4. Verify: `journalctl -b -k | grep "DMUB hardware initialized"`
   must show `version=0x09002C01` or higher.

Worth reporting to Launchpad against `linux-firmware` — the split packaging
regresses AMD DMCUB on Strix Point.

## Fix applied (2026-09-20)

`dcn_3_5_dmcub.bin` from upstream `linux-firmware.git` tag `20250917` carries exactly
DMUB `0x09002C01` (tag `20241210` is the `0x09000D00` the Ubuntu split package
ships). The script downloads it, verifies SHA-256
`ce5dc8ef543ce71a0ef772d4d821872fbfaa48afd0634e00f814e04ed991c431`, installs it to
`/lib/firmware/updates/amdgpu/dcn_3_5_dmcub.bin` and refreshes the initramfs.

```bash
bash configs/amdgpu/amdgpu-dmub-fix.sh --check   # loaded / packaged / override versions
sudo bash configs/amdgpu/amdgpu-dmub-fix.sh      # install, then reboot
sudo bash configs/amdgpu/amdgpu-dmub-fix.sh --revert
```

Drop the override (`--revert`) once `linux-firmware-amd-graphics` ships a DMUB newer
than `0x09002C01`; `--check` shows both versions side by side.

## Rejected mitigation

`amdgpu.dcdebugmask=0x10` (disables Panel Self Refresh) avoids the hang
without touching firmware, but **costs battery life — explicitly not wanted.**
Do not apply. Fix the firmware instead.

## Observed while unfixed

Crashes correlated with
display activity (an external monitor on the NVIDIA GPU via HDMI,
internal eDP on the AMD iGPU).
