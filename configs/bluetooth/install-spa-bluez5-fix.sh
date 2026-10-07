#!/bin/bash
#
# install-spa-bluez5-fix.sh - build PipeWire's Bluetooth plugin (libspa-bluez5.so)
# for the installed PipeWire version with the HFP AT+BCC fix and make WirePlumber
# load it. User-local, no system file is modified.
#
# The bug (PipeWire issue #5506, present up to at least 1.6.9): when a headset
# sends AT+BCC during the eSCO (call audio) setup and then confirms the codec
# already in use, the native HFP backend frees the transport and closes the SCO
# socket mid-connect. The controller completes the link anyway, the host has no
# owner for it, and every later call-audio setup to that headset is refused
# until it reconnects. Symptom: headset microphone works once per connection.
# See pipewire-hfp-atbcc-fix/*.patch and diagnostics/bt-msbc-esco-mt7925-2026-10-02.md.
#
# What it installs:
#   ~/.local/lib/spa-0.2-patched/<pipewire version>/bluez5/libspa-bluez5.so
#   ~/.local/lib/spa-0.2-patched/current  -> symlink chosen at WirePlumber start
#   ~/.local/lib/spa-0.2-patched/select-plugin-dir.sh   (the chooser)
#   ~/.config/systemd/user/wireplumber.service.d/g14-spa-bluez5-fix.conf
# The drop-in puts the patched directory in front of the system plugin
# directory. The chooser runs before every WirePlumber start and only selects a
# patched build that matches the installed PipeWire version; after a PipeWire
# upgrade it falls back to the system plugin and logs a warning, so nothing
# mismatched is ever loaded. Codec plugins (SBC, aptX, LDAC, ...) keep coming
# from the system directory; only libspa-bluez5.so is replaced.
#
# Usage (as desktop user, no root):
#   bash configs/bluetooth/install-spa-bluez5-fix.sh            # build, install, restart WirePlumber
#   bash configs/bluetooth/install-spa-bluez5-fix.sh --check    # versions, what WirePlumber has loaded
#   bash configs/bluetooth/install-spa-bluez5-fix.sh --revert   # remove drop-in + builds, restart WirePlumber
#   bash configs/bluetooth/install-spa-bluez5-fix.sh --build-only
#
# Build dependencies (Ubuntu 24.04):
#   sudo apt install meson ninja-build pkg-config libdbus-1-dev libglib2.0-dev \
#        libsbc-dev libbluetooth-dev libusb-1.0-0-dev libsystemd-dev
# Restarting WirePlumber interrupts audio for about a second; reconnect the
# headset afterwards (its profiles are re-enumerated).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="$HERE/pipewire-hfp-atbcc-fix"
BASE="$HOME/.local/lib/spa-0.2-patched"
CHOOSER="$BASE/select-plugin-dir.sh"
DROPIN_DIR="$HOME/.config/systemd/user/wireplumber.service.d"
DROPIN="$DROPIN_DIR/g14-spa-bluez5-fix.conf"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/g14-spa-bluez5-fix"

# upstream release tarballs (GitHub mirror of gitlab.freedesktop.org/pipewire)
# version  sha256
KNOWN_TARBALLS="
1.0.5 c5a5de26d684a1a84060ad7b6131654fb2835e03fccad85059be92f8e3ffe993
"

pw_version() { pipewire --version 2>/dev/null | awk '/^Compiled with/ {print $NF; exit}'; }
system_spa_dir() {
    local f; f=$(find /usr/lib /usr/lib64 -path '*/spa-0.2/bluez5/libspa-bluez5.so' 2>/dev/null | head -1)
    [ -n "$f" ] && dirname "$(dirname "$f")"
}

check() {
    local ver sysdir cur
    ver=$(pw_version || true); sysdir=$(system_spa_dir || true)
    echo "PipeWire installed      : ${ver:-unknown}"
    echo "System SPA plugin dir   : ${sysdir:-not found}"
    echo "Patched builds present  : $(ls -d "$BASE"/[0-9]* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || true)"
    cur=$(readlink "$BASE/current" 2>/dev/null || echo none)
    echo "Chooser symlink current : $cur"
    if [ -f "$DROPIN" ]; then echo "WirePlumber drop-in     : yes ($DROPIN)"; else echo "WirePlumber drop-in     : no"; fi
    local pid; pid=$(pidof wireplumber 2>/dev/null | awk '{print $1}')
    if [ -n "$pid" ]; then
        if grep -q "spa-0.2-patched/.*/libspa-bluez5.so" "/proc/$pid/maps" 2>/dev/null; then
            echo "WirePlumber has loaded  : PATCHED libspa-bluez5.so"
        elif grep -q "libspa-bluez5.so" "/proc/$pid/maps" 2>/dev/null; then
            echo "WirePlumber has loaded  : system libspa-bluez5.so (not patched)"
        else
            echo "WirePlumber has loaded  : no bluez5 plugin yet (no Bluetooth audio device connected?)"
        fi
    else
        echo "WirePlumber has loaded  : wireplumber not running"
    fi
    local n; n=$(journalctl --user -b -u wireplumber --no-pager -o cat 2>/dev/null | grep -c 'codec unchanged, keeping transport' || true)
    echo "Fix triggered this boot : ${n:-0} times (visible only with WIREPLUMBER_DEBUG=5,spa.bluez5*)"
}

need_build_deps() {
    local missing=()
    command -v meson >/dev/null || missing+=(meson)
    command -v ninja >/dev/null || missing+=(ninja-build)
    command -v pkg-config >/dev/null || missing+=(pkg-config)
    for m in dbus-1:libdbus-1-dev glib-2.0:libglib2.0-dev gio-2.0:libglib2.0-dev sbc:libsbc-dev bluez:libbluetooth-dev libusb-1.0:libusb-1.0-0-dev libsystemd:libsystemd-dev; do
        pkg-config --exists "${m%%:*}" 2>/dev/null || missing+=("${m##*:}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing build dependencies. Install them with:" >&2
        echo "  sudo apt install $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')" >&2
        return 1
    fi
}

build() {
    local ver sha url tarball src
    ver=$(pw_version) || { echo "pipewire not found" >&2; exit 1; }
    sha=$(echo "$KNOWN_TARBALLS" | awk -v v="$ver" '$1==v {print $2}')
    if [ -z "$sha" ]; then
        echo "No pinned checksum for PipeWire $ver in this script; add the upstream tarball sha256 to KNOWN_TARBALLS first." >&2
        exit 1
    fi
    need_build_deps
    mkdir -p "$WORK"; tarball="$WORK/pipewire-$ver.tar.gz"; src="$WORK/pipewire-$ver"
    url="https://github.com/PipeWire/pipewire/archive/refs/tags/$ver.tar.gz"
    if [ ! -f "$tarball" ] || ! echo "$sha  $tarball" | sha256sum -c --quiet - >/dev/null 2>&1; then
        echo "Downloading PipeWire $ver source..."
        curl -fsSL --retry 3 -o "$tarball" "$url"
        echo "$sha  $tarball" | sha256sum -c --quiet - || { echo "Checksum mismatch for $tarball" >&2; exit 1; }
    fi
    rm -rf "$src"; tar -xzf "$tarball" -C "$WORK"
    for p in "$PATCH_DIR"/*.patch; do
        if patch -d "$src" -p1 --dry-run -s < "$p" >/dev/null 2>&1; then
            patch -d "$src" -p1 -s < "$p"; echo "applied: $(basename "$p")"
        elif patch -d "$src" -p1 -R --dry-run -s < "$p" >/dev/null 2>&1; then
            echo "already contained in $ver, skipped: $(basename "$p")"
        else
            echo "ERROR: $(basename "$p") does not apply to PipeWire $ver" >&2; exit 1
        fi
    done
    echo "Configuring (only the bluez5 plugin is built)..."
    meson setup "$src/build" "$src" --buildtype=release -Dauto_features=disabled \
        -Dspa-plugins=enabled -Dbluez5=enabled -Dbluez5-backend-hsp-native=enabled \
        -Dbluez5-backend-hfp-native=enabled -Dbluez5-backend-ofono=enabled \
        -Dbluez5-backend-hsphfpd=enabled -Dbluez5-backend-native-mm=disabled \
        -Dlibusb=enabled -Ddbus=enabled -Dsystemd=enabled \
        -Dtests=disabled -Dexamples=disabled -Dsession-managers='[]' >"$WORK/meson-$ver.log" 2>&1 \
        || { tail -30 "$WORK/meson-$ver.log" >&2; exit 1; }
    ninja -C "$src/build" spa/plugins/bluez5/libspa-bluez5.so >"$WORK/ninja-$ver.log" 2>&1 \
        || { tail -30 "$WORK/ninja-$ver.log" >&2; exit 1; }
    BUILT="$src/build/spa/plugins/bluez5/libspa-bluez5.so"
    echo "Built: $BUILT"
    BUILT_VER="$ver"
}

install_fix() {
    local sysdir; sysdir=$(system_spa_dir) || { echo "system spa-0.2 directory not found" >&2; exit 1; }
    install -D -m 0755 "$BUILT" "$BASE/$BUILT_VER/bluez5/libspa-bluez5.so"
    cat > "$CHOOSER" <<CH
#!/bin/bash
# Written by install-spa-bluez5-fix.sh. Runs before WirePlumber starts and points
# 'current' at the patched plugin build matching the installed PipeWire version,
# or at the system plugin directory when there is none (after a PipeWire upgrade).
BASE="$BASE"
SYS="$sysdir"
ver=\$(pipewire --version 2>/dev/null | awk '/^Compiled with/ {print \$NF; exit}')
if [ -n "\$ver" ] && [ -f "\$BASE/\$ver/bluez5/libspa-bluez5.so" ]; then
    ln -sfn "\$BASE/\$ver" "\$BASE/current"
else
    ln -sfn "\$SYS" "\$BASE/current"
    echo "g14-spa-bluez5-fix: no patched plugin for PipeWire \${ver:-?}, using system plugin; re-run install-spa-bluez5-fix.sh" >&2
fi
exit 0
CH
    chmod 0755 "$CHOOSER"
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<DI
# Written by install-spa-bluez5-fix.sh (ASUS-ROG-Zephyrus-G14-fixes).
# Loads the patched Bluetooth SPA plugin with the HFP AT+BCC fix before the
# system one; the chooser falls back to the system plugin on version mismatch.
[Service]
ExecStartPre=$CHOOSER
Environment=SPA_PLUGIN_DIR=$BASE/current:$sysdir
DI
    "$CHOOSER"
    systemctl --user daemon-reload
    echo "Restarting WirePlumber (short audio interruption)..."
    systemctl --user restart wireplumber; sleep 3
    systemctl --user is-active --quiet wireplumber || { echo "WirePlumber failed to start: journalctl --user -u wireplumber" >&2; exit 1; }
    echo; check
    echo; echo "Done. Disconnect and reconnect the headset once, then test with:"
    echo "  bash $HERE/bt-headset-mic-test.sh -n 8"
}

case "${1:-}" in
    --check) check ;;
    --build-only) build ;;
    --revert)
        rm -fv "$DROPIN"; rmdir --ignore-fail-on-non-empty "$DROPIN_DIR" 2>/dev/null || true
        rm -rf "$BASE"; echo "removed $BASE"
        systemctl --user daemon-reload
        echo "Restarting WirePlumber (short audio interruption)..."
        systemctl --user restart wireplumber; sleep 3; check ;;
    "") build; install_fix ;;
    *) echo "Usage: $0 [--check|--revert|--build-only]" >&2; exit 2 ;;
esac
