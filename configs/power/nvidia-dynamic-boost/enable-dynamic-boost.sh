#!/usr/bin/env bash
# Enable NVIDIA Dynamic Boost (nvidia-powerd) so the laptop dGPU can exceed its 80 W base TGP (up to 120 W).
set -euo pipefail
cd "$(dirname "$0")"
sudo cp nvidia-powerd.service /etc/systemd/system/nvidia-powerd.service
sudo cp nvidia-dbus.conf /usr/share/dbus-1/system.d/nvidia-dbus.conf
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-powerd
echo "Boost only engages in the 'performance' platform profile: powerprofilesctl set performance"
