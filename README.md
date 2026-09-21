# ASUS ROG Zephyrus G14 (GA403WR, late 2025 / early 2026) Linux Tweaks

Practical configuration files and scripts for Ubuntu 24.04 on the ASUS ROG Zephyrus G14 GA403WR (late 2025 / early 2026
model: AMD Ryzen AI 9 HX 370 with Radeon 890M iGPU, NVIDIA RTX 5070 Ti Laptop dGPU, MediaTek MT7925 Wi-Fi 7).

This is one person's working setup, kept in the open so others with the same or a similar machine (GA403 series,
other Strix Point laptops with an NVIDIA dGPU and an MT7925 card) can reuse the fixes and the reasoning behind
them. Every script says what it changes, most have `--check` and `--revert`, and the measurements quoted below were
taken on this machine on the dates given. Read a script before running it with `sudo`; paths such as the dGPU PCI
address (`0000:64:00.0`) or the Wi-Fi interface (`wlp99s0`) may differ on yours, the scripts detect them where they can.

Highlights, if you only came for one thing:

- **Random hard freeze after a `linux-firmware` update** (Sep 2026): AMD DMUB firmware downgrade, see step 5b.
- **dGPU never sleeps in Hybrid mode, 8 W extra on battery**: a GPU monitor polling `nvidia-smi`, see step 4 and
  "GPU switching".
- **Wi-Fi drops / rate collapse with MT7925**: firmware pin first, ASPM off second, see Troubleshooting.
- **Bluetooth headset mic missing in calls, re-pairing after every Windows boot**: see the Bluetooth section.

## What this repository includes

- [configs/grub/grub](configs/grub/grub): GRUB defaults for NVIDIA and dual-boot friendly behavior.
- [configs/amdgpu/amdgpu-dmub-fix.sh](configs/amdgpu/amdgpu-dmub-fix.sh): Pins the known-good AMD DMUB display firmware (fixes the random hard freeze, see [diagnostics](diagnostics/amdgpu-dmcub-freeze-2026-09-14.md)).
- [configs/cirrus/cirrus-fix.sh](configs/cirrus/cirrus-fix.sh): Creates Cirrus CS35L56 firmware links. **Obsolete** with current `linux-firmware`; refuses to run when not needed.
- [configs/cirrus/cirrus-cleanup.sh](configs/cirrus/cirrus-cleanup.sh): Removes hand-installed CS35L56 files left by older `cirrus-fix.sh` runs so the package owns them again.
- [configs/gnome/vitals-setup.sh](configs/gnome/vitals-setup.sh): Configures GNOME Vitals panel sensors. GPU sensors are enabled only when the power-safe `nvidia-smi` wrapper is installed.
- [configs/gnome/nvidia-smi-powersafe](configs/gnome/nvidia-smi-powersafe) + [install-nvidia-smi-powersafe.sh](configs/gnome/install-nvidia-smi-powersafe.sh): `/usr/local/bin/nvidia-smi` wrapper that answers looping `--query-gpu` polls (Vitals) from sysfs while the dGPU is asleep or unused, and only runs the real `nvidia-smi` while a client holds the GPU. Plain `nvidia-smi` calls pass straight through.
- [configs/gnome/vitals-na-patch.sh](configs/gnome/vitals-na-patch.sh): One-line local patch to Vitals so an unavailable GPU value renders as `N/A` instead of the last number staying in the panel (`--check` / `--revert`, re-applied by `vitals-setup.sh`).
- [configs/NetworkManager/wifi-powersave-off.conf](configs/NetworkManager/wifi-powersave-off.conf): Disables WiFi powersave in NetworkManager.
- [configs/mt76-pm-fix/revert-to-stock-oem.sh](configs/mt76-pm-fix/revert-to-stock-oem.sh): Resets MT7925 WiFi to stock OEM baseline.
- [configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh](configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh): Pins MT7925 Wi-Fi + Bluetooth firmware to a checksum-verified upstream `linux-firmware` tag as an override (preferred first fix path); `--check` compares loaded / packaged / override builds, `--revert` removes the override.
- [configs/mt76-pm-fix/apply-mt7925-aspm-off.sh](configs/mt76-pm-fix/apply-mt7925-aspm-off.sh): Applies persistent MT7925 power-management hardening (`disable_aspm=Y`, NM powersave off, runtime PM off).
- [configs/mt76-pm-fix/recover-wifi.sh](configs/mt76-pm-fix/recover-wifi.sh): Fast WiFi recovery helper (`reconnect` or `full reload`).
- [configs/bluetooth/install-bt-headset-autoswitch.sh](configs/bluetooth/install-bt-headset-autoswitch.sh): WirePlumber 0.4 override so a Bluetooth headset switches to its microphone (HSP/HFP) profile for calls even when HDMI/speakers are the default output; `--check` / `--revert`.
- [configs/bluetooth/import-bt-linkkey.sh](configs/bluetooth/import-bt-linkkey.sh): Writes the Windows-negotiated Bluetooth link key into BlueZ so a headset stays paired in both OSes (dual boot).
- [configs/power/g14-power-mode.sh](configs/power/g14-power-mode.sh): Maps Ubuntu power profile + AC/DC to ASUS profile and GPU policy.
- [configs/power/g14-set-refresh.py](configs/power/g14-set-refresh.py): Applies monitor refresh changes via GNOME Mutter DisplayConfig.
- [configs/power/g14-dgpu-sleep-check.sh](configs/power/g14-dgpu-sleep-check.sh): Read-only check whether the NVIDIA dGPU is in runtime D3, what holds it open, and the battery draw (never calls `nvidia-smi`).
- [configs/power/root/g14-cpu-policy-apply.sh](configs/power/root/g14-cpu-policy-apply.sh): Root helper to apply CPU boost/EPP/governor policy.
- [configs/power/root/install-root-cpu-helper.sh](configs/power/root/install-root-cpu-helper.sh): One-time installer for passwordless sudo rule (CPU helper only).
- [configs/power/root/g14-gpu-runtimepm-apply.sh](configs/power/root/g14-gpu-runtimepm-apply.sh): Root helper to enforce NVIDIA PCI runtime PM `power/control=auto`.
- [configs/power/root/install-root-gpu-runtimepm-helper.sh](configs/power/root/install-root-gpu-runtimepm-helper.sh): One-time installer for passwordless sudo rule (GPU runtime PM helper only).
- [configs/power/install.sh](configs/power/install.sh): Installs user service and applies startup defaults for power mapping.
- [configs/power/systemd-user/g14-power-acdc-monitor.service](configs/power/systemd-user/g14-power-acdc-monitor.service): Re-applies mapping when AC state or Ubuntu power profile changes.
- [configs/power/systemd-user/g14-power-startup-eco.service](configs/power/systemd-user/g14-power-startup-eco.service): Forces startup default to Eco (`Power Saver`) on login.

## Target setup

- Ubuntu 24.04 (GNOME/Wayland)
- `linux-generic-hwe-24.04` (kernel 7.0) as the daily kernel, `linux-oem-24.04d` (6.17) kept as fallback boot entry
- `nvidia-driver-580-open`
- In-tree `mt7925e` driver
- Ubuntu `linux-firmware` (split per-vendor packages since Sep 2026), plus two pinned overrides in
  `/lib/firmware/updates/` (AMD DMUB, MT7925), each managed by a script here with `--check` / `--revert`

## Quick setup

### 1) Install NVIDIA open driver branch

```bash
sudo apt update
sudo apt install nvidia-driver-580-open
```

### 2) Cirrus speaker firmware

Not needed anymore: current `linux-firmware` ships the `10431024` CS35L56 files and the kernel log shows
`Calibration applied`. If you ran `cirrus-fix.sh` on an older install, remove its leftovers so package updates take effect:

```bash
bash configs/cirrus/cirrus-cleanup.sh          # dry run
sudo bash configs/cirrus/cirrus-cleanup.sh --yes
```

The headset-mic quirk for PCI SSID `1043:1024` is built into kernel 7.0 (`ALC285_FIXUP_ASUS_GA403U_HEADSET_MIC`).

### 3) Apply GRUB configuration

```bash
sudo cp configs/grub/grub /etc/default/grub
sudo update-grub
```

### 4) Configure GNOME Vitals (run as desktop user)

```bash
sudo bash configs/gnome/install-nvidia-smi-powersafe.sh   # lets Vitals show GPU % without keeping the dGPU awake
bash configs/gnome/vitals-setup.sh
```

Without the wrapper the setup script leaves GPU sensors off: Vitals' `nvidia-smi -l 1` loop costs ~8 W on battery
(see "GPU switching" below). With it, GPU % reads `N/A` while the dGPU sleeps or nobody uses it, and real values
appear as soon as a job holds the GPU (training run, offloaded app). The `N/A` needs the one-line Vitals patch that
`vitals-setup.sh` applies: stock Vitals drops non-numeric values and keeps the last number in the panel. Log out and
back in once after the patch, GNOME Shell loads extension code per session. Should a Vitals update remove the patch,
the wrapper notices and falls back to reporting `0` for utilization, clocks and power (true for a GPU in D3cold)
rather than letting a stale value stand; rerun `vitals-setup.sh` to re-apply.

### 5) Install kernels and current firmware

```bash
sudo apt update
sudo apt install linux-firmware linux-generic-hwe-24.04 linux-oem-24.04d
```

### 5b) Pin the AMD display firmware (freeze fix)

The Sep 2026 `linux-firmware-amd-graphics` package downgrades the Radeon 890M DMUB firmware and causes random hard
freezes (`hw_done or flip_done timed out`). Details in
[diagnostics/amdgpu-dmcub-freeze-2026-09-14.md](diagnostics/amdgpu-dmcub-freeze-2026-09-14.md).

```bash
bash configs/amdgpu/amdgpu-dmub-fix.sh --check
sudo bash configs/amdgpu/amdgpu-dmub-fix.sh      # then reboot; --check must show 0x09002C01 loaded
```

### 6) Apply WiFi powersave policy

```bash
sudo install -D -m 644 configs/NetworkManager/wifi-powersave-off.conf \
  /etc/NetworkManager/conf.d/wifi-powersave-off.conf
sudo systemctl restart NetworkManager
```

### 7) Install power profile mapping (Ubuntu menu driven)

```bash
bash configs/power/install.sh
sudo systemctl enable --now supergfxd.service
sudo bash configs/power/root/install-root-cpu-helper.sh
sudo bash configs/power/root/install-root-gpu-runtimepm-helper.sh
```

This keeps Ubuntu's built-in top-right power menu as the only mode selector.

### 8) Reboot

```bash
sudo reboot
```

## Power profile mapping (Ubuntu top-right menu)

The active Ubuntu power profile (`Power Saver`, `Balanced`, `Performance`) is mapped automatically with AC/DC awareness.

| Ubuntu menu selection | Power source | ASUS profile | GPU mode | Intent |
|---|---|---|---|---|
| Power Saver | Battery (DC) | Quiet | Hybrid, dGPU asleep via runtime D3 | Power saving (60 Hz) |
| Balanced | Battery (DC) | Balanced | Hybrid | Moderate savings |
| Performance | Battery (DC) | Performance | Hybrid | Maximum performance without reboot-required MUX switching |
| Power Saver | AC | Quiet | Hybrid | Quiet daily use (120 Hz) |
| Balanced | AC | Balanced | Hybrid | Quiet daily use (120 Hz) |
| Performance | AC | Performance | Hybrid | Maximum performance without reboot-required MUX switching (120 Hz) |

The GPU mode is `Hybrid` in every row (`gpu-policy` **hybrid-only**, the default since 2026-09-21): the script never
requests a `supergfxctl` mode change, so plugging, unplugging and rebooting never ask for a logout. The dGPU is
expected to power itself off through NVIDIA runtime D3 when idle; the script re-arms `power/control=auto` on every
mapping change. The previous behaviour (`Integrated` on battery + Power Saver, one logout per switch) is still
available with `echo acdc > ~/.config/g14-power/gpu-policy`.

Notes:

- On AC, `Power Saver` now maps to ASUS `Quiet` (not `Balanced`) so the profile does not bounce back to `Balanced`.
- Every `Integrated` <-> `Hybrid` change requires a logout, in both directions (verified on this machine, see below).
- The background monitor never forces logout; logout/reload is manual when required. `supergfxd` only waits 30 s
  for that logout (observed in its journal even with `logout_timeout_s: 180`); after that it aborts and falls back to
  the previous mode, so a later logout does nothing until the mode is requested again.
- `supergfxd` restores the last mode at boot. Shut down on AC (`Hybrid`) and boot on battery, and the startup service
  requests `Integrated` at login: the dGPU stays powered until you log out within 30 s of that request.
- If a transition is pending, a GNOME desktop notification is shown.
- Startup default is `Power Saver` and is enforced on each login by `g14-power-startup-eco.service`.
- Refresh rate is mapped automatically by power source: `60 Hz` on battery and `120 Hz` on AC.
- Whenever the dGPU is on the bus, `g14-power-mode.sh` re-applies NVIDIA PCI runtime PM `power/control=auto` via the optional root helper (direct sysfs write as fallback).
- `status`, `check` and the AC/DC monitor read the driver binding from sysfs and never call `nvidia-smi`, which would wake a sleeping dGPU.

### Switching to hybrid-only from an Integrated installation (one logout)

Run this from a terminal with nothing unsaved. The logout has to follow the request within 30 s, so it is one line:

```bash
bash configs/power/install.sh                      # installs the hybrid-only script, does not switch yet
~/.local/bin/g14-power-mode.sh apply --logout-on-pending yes   # requests Hybrid and logs out immediately
```

After logging back in, check that the dGPU actually sleeps on battery, once right after login, once after a
suspend/resume, and with no HDMI monitor attached:

```bash
bash configs/power/g14-dgpu-sleep-check.sh          # or --watch
```

Good: `status=suspended power_state=D3cold`, `Video Memory: Off`, battery draw in the same range as Integrated
mode (measured 10 W idle at 60 Hz, same as Integrated at 11 W). Bad: `status=active` for more than a minute with no
dGPU output connected. Then look at `holders:` for a process other than GNOME Shell and Xwayland (`nvidia-smi` from
Vitals was the one here), or fall back to `acdc` policy. Open file descriptors alone do not block runtime D3 with the
fine-grained mode the 580 driver enables; only actual GPU work does.

## GPU switching: what needs a logout, and why the dGPU stays awake

Windows-style "switching" is not a mode change: the iGPU drives the panel and every app, the dGPU wakes only for
apps that ask and powers down when idle. Linux does the same **while already in** `supergfxctl` **Hybrid** mode with
`prime-select on-demand` (Ubuntu default). Using the dGPU per app inside Hybrid needs no logout; getting into or out
of Hybrid does (next section):

- Default rendering is on the Radeon 890M (`glxinfo -B | grep renderer`, `eglinfo -B` Wayland platform).
- Per-app dGPU: *Launch using Discrete Graphics Card* in the GNOME app grid, or
  `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <program>` (`__NV_PRIME_RENDER_OFFLOAD=1` alone for Vulkan).
- Idle dGPU power-off: runtime D3 is enabled (`/proc/driver/nvidia/gpus/0000:64:00.0/power`), state in
  `/sys/bus/pci/devices/0000:64:00.0/power/runtime_status`.

Three things keep the dGPU awake in Hybrid mode:

0. **A monitoring tool polling `nvidia-smi`.** The GNOME Vitals extension with `show-gpu=true` keeps an
   `nvidia-smi -l 1` child of GNOME Shell running for the whole session; every query wakes the GPU, so it never
   reaches D3. Measured 2026-09-21 on battery, panel idle: 18-20 W with the poll, 10 W five seconds after turning it
   off. The same applies to any `nvidia-smi` loop, `nvtop`, or GPU widgets. This was the reason Hybrid mode looked
   as expensive as it did; the Integrated detour and its logouts were only working around it.
   `g14-dgpu-sleep-check.sh` lists such processes as `holders`. Fix: the power-safe wrapper from step 4. It reads
   `power/runtime_status` of the dGPU from sysfs: while `suspended` it prints N/A and never touches the driver.
   While `active` it runs the real `nvidia-smi`, rate-limited so it cannot keep the GPU awake on its own: the first
   sample after a wake-up is immediate, a GPU with utilization above 0 is sampled every second, and after three 0 %
   samples it is sampled at most every 25 s, longer than the driver's ~20 s idle tail after any access, so the GPU
   can drop to D3 in between. `power/runtime_usage` is no help here: it reads 1 both during a running job and during
   the idle tail. Measured: one `nvidia-smi` call keeps the GPU in D0 for 20 s; the wrapper did not delay the
   return to D3cold.
1. **The HDMI port is on the dGPU** (`card1-HDMI-A-1`). With an HDMI monitor attached the dGPU cannot suspend,
   on Windows either. The USB-C ports carry DisplayPort from the iGPU, so a USB-C/DP monitor lets it sleep.
   This is the usual reason `runtime_status` stays `active` after resume on a docked machine.
2. Processes holding the device: `fuser -v /dev/nvidia0`. GNOME Shell holds it in order to drive HDMI; a
   `TAG+="mutter-device-ignore"` udev rule on the NVIDIA DRM device makes Mutter skip the card entirely, at the
   cost of the HDMI port.

Still requires a logout or reboot, unchanged as of `supergfxctl` 5.2.7:

- `Hybrid` -> `Integrated` (dGPU removed from the bus, lowest idle power): logout, because `nvidia` cannot be unloaded while the compositor holds the device.
- `Integrated` -> `Hybrid`: logout as well. Every such request in `~/.local/state/g14-power/apply.log` came back with
  `Logoutrequiredtocompletemodechange`; the compositor has to restart to pick up the re-added card.
- Log out within 30 s of the request. `supergfxd` logs `Time (30 seconds) for logout exceeded`, gives up and reloads
  the old mode; a logout after that changes nothing and the request has to be repeated (`supergfxctl -m <mode>`, then log out).
- `AsusMuxDgpu` (MUX, dGPU drives the panel): reboot, it is an ACPI setting.

## Quick verification

Run these checks after reboot:

```bash
powerprofilesctl get
supergfxctl -g
supergfxctl -S
bash configs/power/g14-power-mode.sh status
```

Expected:

- `supergfxctl` responds quickly.
- `gpu_mode_consistent=yes` in `g14-power-mode.sh status`.
- `requires_logout=yes` only when a transition is pending.

## Bluetooth headset: microphone for calls, pairing shared with Windows

### Headset shows only a "Monitor of ..." input in Teams/Firefox

A Bluetooth headset has two modes: A2DP (stereo music, no microphone) and HSP/HFP (mono, microphone). WirePlumber
0.4.17 switches to HSP/HFP automatically when a call app opens the microphone, but only when the headset is the
**default sink**. Docked to a monitor with HDMI audio as default output, the switch never happens and only the A2DP
sink's monitor is offered as "microphone". The stock policy also remembers whichever profile is active when a call
ends as the profile to use for the next call, so a manual switch back to A2DP mid-call leaves it stuck on the
mic-less profile forever.

```bash
bash configs/bluetooth/install-bt-headset-autoswitch.sh --check   # version, override state, remembered profile
bash configs/bluetooth/install-bt-headset-autoswitch.sh           # install override, restart WirePlumber (1 s audio gap)
```

The override ([configs/bluetooth/wireplumber/policy-bluetooth.lua](configs/bluetooth/wireplumber/policy-bluetooth.lua),
a patched copy of the stock script installed to `~/.config/wireplumber/scripts/`) additionally switches when the headset
is the configured **input** device (GNOME Settings > Sound > Input), and ignores a remembered profile without a
microphone. Pick the headset as input device once; output can stay on HDMI or speakers. Music quality drops to HFP only
while a Communication-role stream (Firefox, Chrome, Teams, Zoom) is open and returns to A2DP two seconds after.

Trap to know: the HFP microphone route keeps its own volume. If the headset switches but stays silent, check the input
level in GNOME Sound settings while a call is running (it was saved as 0 once here). The override is for WirePlumber
0.4.x only; the installer refuses on 0.5+, whose policy is not Lua.

### Re-pairing needed after every Windows boot (dual boot)

A classic Bluetooth device stores one link key per adapter address. Windows and Linux share the adapter but each
pairing creates a new key, so pairing in one OS invalidates the other. Fix once by giving BlueZ the key Windows
negotiated (the Windows system partition here is BitLocker-encrypted, so reading its registry from Linux is
impractical; read the key inside Windows instead):

1. Linux: pair the headset normally so `/var/lib/bluetooth/<adapter>/<device>/info` exists.
2. Windows: remove and re-pair the headset. Windows now holds the valid key.
3. Windows: read the key as SYSTEM (the `Keys` hive is hidden from administrators). With Sysinternals PsExec in an
   admin prompt: `psexec -s -i cmd`, then
   `reg query "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\<adapter mac, no colons>"`.
   The device's line shows a 32-hex-digit `REG_BINARY`. `sudo bash configs/bluetooth/import-bt-linkkey.sh --show <device MAC>`
   prints the exact registry path.
4. Linux: `sudo bash configs/bluetooth/import-bt-linkkey.sh <device MAC> <32 hex digits>`; it backs up the `info` file,
   replaces only the `[LinkKey]` key, restarts `bluetooth.service`.

Repeat step 2 to 4 only if one OS is re-paired again. Re-pairing does not lose the WirePlumber settings above: they are
keyed by the headset's address, which does not change.

## Troubleshooting (only if needed)

Preferred first fix path for recurrent MT7925 instability (before PM hardening):

```bash
bash configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh --check   # loaded vs. packaged vs. override builds
sudo bash configs/mt76-pm-fix/apply-mt7925-upstream-firmware.sh      # pin upstream tag 20260916 (build 2026-08-13)
sudo reboot
```

This avoids stacking multiple runtime workarounds and aligns the card with current upstream firmware. Note that an
override in `/lib/firmware/updates/` is loaded in preference to the package forever: re-run the script when
upstream moves on, or `--revert` once `linux-firmware-mediatek` catches up (`--check` shows both builds).
The Bluetooth blob lives in the same directory and is pinned together with Wi-Fi.

If `supergfxctl` hangs and `systemctl restart supergfxd` also hangs:

```bash
systemctl --user stop g14-power-acdc-monitor.service g14-power-startup-eco.service
sudo bash configs/power/root/cleanup-obsolete-gpu-boot-helper.sh
sudo reboot
```

If your system previously used custom MT76 tweaks and you want stock OEM WiFi baseline:

```bash
sudo bash configs/mt76-pm-fix/revert-to-stock-oem.sh
sudo reboot
```

If instability persists after upstream firmware, apply MT7925 PM hardening as fallback:

```bash
sudo bash configs/mt76-pm-fix/apply-mt7925-aspm-off.sh
sudo reboot
```

If you hit MT7925 severe packet loss / rate collapse and want the stable workaround:

```bash
sudo bash configs/mt76-pm-fix/apply-mt7925-aspm-off.sh
sudo reboot
```

Quickly inspect WiFi power-management state (after reboot):

```bash
iw dev wlp99s0 get power_save
cat /sys/module/mt7925e/parameters/disable_aspm
for d in /sys/bus/pci/drivers/mt7925e/*:*; do
  echo "$d control=$(cat "$d/power/control" 2>/dev/null) runtime=$(cat "$d/power/runtime_status" 2>/dev/null)"
done
grep -R "wifi.powersave" /etc/NetworkManager/conf.d || true
```

If WiFi collapses and you need quick recovery without reboot:

```bash
bash configs/mt76-pm-fix/recover-wifi.sh --reconnect-only
```

If reconnect-only is not enough:

```bash
bash configs/mt76-pm-fix/recover-wifi.sh --full-reload
```

## License

GPL-3.0, see [LICENSE](LICENSE). No warranty: these scripts change firmware overrides, sudoers rules and kernel module
options on your machine. Each one is meant to be read first.
