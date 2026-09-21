# NVIDIA Dynamic Boost (nvidia-powerd) on the G14

Without `nvidia-powerd` the RTX 5070 Ti Laptop stays at its 80 W base TGP (`nvidia-smi -q -d POWER` shows
Current/Default Power Limit 80 W, "SW Power Cap" active) although the ASUS firmware allows 95 W static TGP plus a 25 W
Dynamic Boost allowance (`/sys/class/firmware-attributes/asus-armoury/attributes/nv_tgp`, `nv_dynamic_boost`; max 120 W).
Ubuntu's `nvidia-kernel-common-580` ships `/usr/bin/nvidia-powerd` but installs the systemd unit only under
`/usr/share/doc/` and omits the D-Bus policy entirely, so supergfxd's attempt to start `nvidia-powerd.service` fails
silently at every boot.

`enable-dynamic-boost.sh` installs `nvidia-powerd.service` and `nvidia-dbus.conf` and enables the daemon.

Measured with an LLM decode workload (CPU idle):

| Profile | Power limit under load | Speed |
|---|---|---|
| quiet | stays at 80 W | 30 tok/s |
| performance | 100–110 W | 44 tok/s |

Boost only engages in the `performance` platform profile. On battery keep the quiet profile; the daemon idles when the
dGPU is runtime-suspended, verify with `configs/power/g14-dgpu-sleep-check.sh`.

