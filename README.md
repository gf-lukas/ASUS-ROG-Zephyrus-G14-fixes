# ASUS ROG Zephyrus G14 (2025) Linux Tweaks

Practical configuration files and scripts for Ubuntu 24.04 on the ASUS ROG Zephyrus G14 2025 (GA403WR).

## What this repository includes

- [configs/grub/grub](configs/grub/grub): GRUB defaults for NVIDIA and dual-boot friendly behavior.
- [configs/cirrus/cirrus-fix.sh](configs/cirrus/cirrus-fix.sh): Creates required Cirrus CS35L56 firmware links.
- [configs/gnome/vitals-setup.sh](configs/gnome/vitals-setup.sh): Configures GNOME Vitals panel sensors.
- [configs/NetworkManager/wifi-powersave-off.conf](configs/NetworkManager/wifi-powersave-off.conf): Disables WiFi powersave in NetworkManager.
- [configs/mt76-pm-fix/revert-to-stock-oem.sh](configs/mt76-pm-fix/revert-to-stock-oem.sh): Resets MT7925 WiFi to stock OEM baseline.
- [configs/power/g14-power-mode.sh](configs/power/g14-power-mode.sh): Maps Ubuntu power profile + AC/DC to ASUS profile and GPU policy.
- [configs/power/g14-set-refresh.py](configs/power/g14-set-refresh.py): Applies monitor refresh changes via GNOME Mutter DisplayConfig.
- [configs/power/root/g14-cpu-policy-apply.sh](configs/power/root/g14-cpu-policy-apply.sh): Root helper to apply CPU boost/EPP/governor policy.
- [configs/power/root/install-root-cpu-helper.sh](configs/power/root/install-root-cpu-helper.sh): One-time installer for passwordless sudo rule (CPU helper only).
- [configs/power/install.sh](configs/power/install.sh): Installs user service and applies startup defaults for power mapping.
- [configs/power/systemd-user/g14-power-acdc-monitor.service](configs/power/systemd-user/g14-power-acdc-monitor.service): Re-applies mapping when AC state or Ubuntu power profile changes.
- [configs/power/systemd-user/g14-power-startup-eco.service](configs/power/systemd-user/g14-power-startup-eco.service): Forces startup default to Eco (`Power Saver`) on login.

## Target setup

- Ubuntu 24.04 (GNOME/Wayland)
- `linux-oem-24.04b`
- In-tree `mt7925e` driver
- Ubuntu `linux-firmware`

## Quick setup

### 1) Install NVIDIA open driver branch

```bash
sudo apt update
sudo apt install nvidia-driver-570-open
```

### 2) Apply Cirrus speaker firmware links

```bash
sudo bash configs/cirrus/cirrus-fix.sh
```

### 3) Apply GRUB configuration

```bash
sudo cp configs/grub/grub /etc/default/grub
sudo update-grub
```

### 4) Configure GNOME Vitals (run as desktop user)

```bash
bash configs/gnome/vitals-setup.sh
```

### 5) Install OEM kernel line and current firmware

```bash
sudo apt update
sudo apt install linux-firmware linux-oem-24.04b linux-image-oem-24.04b
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
```

This keeps Ubuntu's built-in top-right power menu as the only mode selector.

### 8) Reboot

```bash
sudo reboot
```

## Power profile mapping (Ubuntu top-right menu)

The active Ubuntu power profile (`Power Saver`, `Balanced`, `Performance`) is mapped automatically with AC/DC awareness.

| Ubuntu menu selection | Power source | ASUS profile | GPU policy | Intent |
|---|---|---|---|---|
| Power Saver | Battery (DC) | Quiet | Integrated | Ultra power saving (60 Hz) |
| Balanced | Battery (DC) | Balanced | Hybrid | Moderate savings |
| Performance | Battery (DC) | Performance | Hybrid | Maximum performance without reboot-required MUX switching |
| Power Saver | AC | Quiet | Hybrid | Quiet daily use (120 Hz) |
| Balanced | AC | Balanced | Hybrid | Quiet daily use (120 Hz) |
| Performance | AC | Performance | Hybrid | Maximum performance without reboot-required MUX switching (120 Hz) |

Notes:

- On AC, `Power Saver` now maps to ASUS `Quiet` (not `Balanced`) so the profile does not bounce back to `Balanced`.
- GPU mode changes may require a session reload/log out depending on current mode.
- The background monitor never forces logout; logout/reload is manual when required.
- If a transition is pending, a GNOME desktop notification is shown.
- Startup default is `Power Saver` and is enforced on each login by `g14-power-startup-eco.service`.
- Refresh rate is mapped automatically by power source: `60 Hz` on battery and `120 Hz` on AC.

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

## Troubleshooting (only if needed)

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
