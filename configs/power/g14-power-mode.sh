#!/bin/bash
set -euo pipefail

SCRIPT_NAME="g14-power-mode"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/g14-power"
LOG_FILE="$STATE_DIR/apply.log"
REPORTED_MODE_FILE="$STATE_DIR/reported_mode"
NOTIFY_STATE_FILE="$STATE_DIR/last_notify"
REFRESH_STATE_FILE="$STATE_DIR/last_refresh_target"
REFRESH_DC_HZ="${G14_REFRESH_DC_HZ:-60}"
REFRESH_AC_HZ="${G14_REFRESH_AC_HZ:-120}"
REFRESH_OUTPUT="${G14_REFRESH_OUTPUT:-auto}"
REFRESH_HELPER="${HOME}/.local/bin/g14-set-refresh.py"
CPU_BOOST_PATH="/sys/devices/system/cpu/cpufreq/boost"
CPU_POLICY_HELPER="${G14_CPU_POLICY_HELPER:-/usr/local/bin/g14-cpu-policy-apply.sh}"
GPU_RUNTIMEPM_HELPER="${G14_GPU_RUNTIMEPM_HELPER:-/usr/local/bin/g14-gpu-runtimepm-apply.sh}"
# GPU policy:
#   hybrid-only : never leave supergfxctl Hybrid; rely on NVIDIA runtime D3 for idle dGPU power-off (no logouts).
#   acdc        : legacy mapping, Power Saver on battery requests Integrated (every switch needs a logout within 30 s).
GPU_POLICY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/g14-power/gpu-policy"
GPU_POLICY="${G14_GPU_POLICY:-}"
if [[ -z "$GPU_POLICY" && -r "$GPU_POLICY_FILE" ]]; then
  GPU_POLICY="$(tr -d '[:space:]' < "$GPU_POLICY_FILE")"
fi
GPU_POLICY="${GPU_POLICY:-hybrid-only}"

mkdir -p "$STATE_DIR"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$*" | tee -a "$LOG_FILE" >/dev/null
}

warn() {
  log "WARN: $*"
}

die() {
  log "ERROR: $*"
  echo "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

normalize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

is_positive_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

set_cpu_boost() {
  local target="$1"

  if [[ ! -e "$CPU_BOOST_PATH" ]]; then
    warn "CPU boost control not available at $CPU_BOOST_PATH"
    return
  fi

  if [[ ! -w "$CPU_BOOST_PATH" ]]; then
    warn "Cannot write CPU boost policy (need elevated permissions): $CPU_BOOST_PATH"
    return
  fi

  local current
  current="$(cat "$CPU_BOOST_PATH" 2>/dev/null || true)"
  if [[ "$current" == "$target" ]]; then
    return
  fi

  if printf '%s\n' "$target" > "$CPU_BOOST_PATH" 2>/dev/null; then
    if [[ "$target" == "0" ]]; then
      log "Set CPU boost: disabled"
    else
      log "Set CPU boost: enabled"
    fi
  else
    warn "Failed to set CPU boost to $target"
  fi
}

set_epp() {
  local desired="$1"
  local file
  local has_any="no"
  local writable_any="no"
  local wrote_any="no"

  shopt -s nullglob
  for file in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
    has_any="yes"
    [[ -w "$file" ]] && writable_any="yes"
  done

  if [[ "$has_any" == "no" ]]; then
    shopt -u nullglob
    return
  fi

  if [[ "$writable_any" == "no" ]]; then
    warn "Cannot write EPP policy (need elevated permissions)"
    shopt -u nullglob
    return
  fi

  for file in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
    [[ -w "$file" ]] || continue

    if printf '%s\n' "$desired" > "$file" 2>/dev/null; then
      wrote_any="yes"
    else
      warn "Failed to set EPP '$desired' on $file"
    fi
  done
  shopt -u nullglob

  if [[ "$wrote_any" == "yes" ]]; then
    log "Set CPU EPP policy: $desired"
  fi
}

set_cpu_governor() {
  local desired="$1"
  local file avail current
  local has_any="no"
  local writable_any="no"
  local wrote_any="no"

  shopt -s nullglob
  for file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    has_any="yes"
    [[ -r "$file" && -w "$file" ]] && writable_any="yes"
  done

  if [[ "$has_any" == "no" ]]; then
    shopt -u nullglob
    return
  fi

  if [[ "$writable_any" == "no" ]]; then
    warn "Cannot write CPU governor (need elevated permissions)"
    shopt -u nullglob
    return
  fi

  for file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [[ -r "$file" && -w "$file" ]] || continue

    avail="$(cat "${file%/*}/scaling_available_governors" 2>/dev/null || true)"
    if [[ -n "$avail" && ! " $avail " =~ [[:space:]]${desired}[[:space:]] ]]; then
      continue
    fi

    current="$(cat "$file" 2>/dev/null || true)"
    if [[ "$current" == "$desired" ]]; then
      continue
    fi

    if printf '%s\n' "$desired" > "$file" 2>/dev/null; then
      wrote_any="yes"
    else
      warn "Failed to set CPU governor '$desired' on $file"
    fi
  done
  shopt -u nullglob

  if [[ "$wrote_any" == "yes" ]]; then
    log "Set CPU governor: $desired"
  fi
}

apply_cpu_policy_with_root_helper() {
  local ppd="$1"

  [[ -x "$CPU_POLICY_HELPER" ]] || return 1
  has_cmd sudo || return 1

  if sudo -n "$CPU_POLICY_HELPER" "$ppd" >/dev/null 2>&1; then
    log "Applied CPU policy via root helper: $ppd"
    return 0
  fi

  warn "Root CPU helper exists but passwordless sudo is not configured or failed"
  return 1
}

apply_cpu_policy() {
  local ppd="$1"

  if apply_cpu_policy_with_root_helper "$ppd"; then
    return
  fi

  case "$ppd" in
    power-saver)
      set_cpu_boost "0"
      set_epp "power"
      set_cpu_governor "powersave"
      ;;
    balanced)
      set_cpu_boost "1"
      set_epp "balance_power"
      set_cpu_governor "powersave"
      ;;
    performance)
      set_cpu_boost "1"
      set_epp "performance"
      set_cpu_governor "performance"
      ;;
  esac

  if [[ "$ppd" == "performance" && -r "$CPU_BOOST_PATH" ]]; then
    local boost_now
    boost_now="$(cat "$CPU_BOOST_PATH" 2>/dev/null || true)"
    if [[ "$boost_now" != "1" ]]; then
      warn "Performance mode active but CPU boost is '$boost_now' (expected 1); max performance is not fully enabled"
      warn "Run once with sudo: echo 1 > $CPU_BOOST_PATH"
    fi
  fi
}

apply_gpu_runtimepm_with_root_helper() {
  [[ -x "$GPU_RUNTIMEPM_HELPER" ]] || return 1
  has_cmd sudo || return 1

  if sudo -n "$GPU_RUNTIMEPM_HELPER" >/dev/null 2>&1; then
    log "Applied dGPU runtime PM via root helper"
    return 0
  fi

  warn "Root GPU runtime PM helper exists but passwordless sudo is not configured or failed"
  return 1
}

enforce_dgpu_runtimepm_auto() {
  local need_fix="no"

  if [[ "$(effective_gpu_class)" == "integrated" ]]; then
    return
  fi

  if dgpu_pci_present; then
    need_fix="yes"
  fi

  [[ "$need_fix" == "yes" ]] || return

  if apply_gpu_runtimepm_with_root_helper; then
    return
  fi

  local bdf dev
  bdf="$(find_nvidia_gpu_bdf || true)"
  [[ -n "$bdf" ]] || return
  dev="/sys/bus/pci/devices/$bdf"

  if [[ -w "$dev/power/control" ]]; then
    printf '%s\n' auto > "$dev/power/control" 2>/dev/null || true
    log "Set dGPU runtime PM to auto (direct): bdf=$bdf"
  else
    warn "Cannot set dGPU runtime PM to auto (need elevated permissions): $dev/power/control"
  fi
}

get_power_source() {
  local ac
  for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online /sys/class/power_supply/ACAD/online; do
    if [[ -f "$ac" ]]; then
      if [[ "$(cat "$ac")" == "1" ]]; then
        echo "ac"
      else
        echo "dc"
      fi
      return
    fi
  done

  if has_cmd upower && upower -e | grep -q line_power; then
    if upower -i "$(upower -e | grep line_power | head -n1)" | grep -qi 'online:\s*yes'; then
      echo "ac"
    else
      echo "dc"
    fi
    return
  fi

  echo "dc"
}

select_refresh_target() {
  local source="$1"
  if [[ "$source" == "dc" ]]; then
    echo "$REFRESH_DC_HZ"
  else
    echo "$REFRESH_AC_HZ"
  fi
}

detect_output_xrandr() {
  if [[ "$REFRESH_OUTPUT" != "auto" ]]; then
    echo "$REFRESH_OUTPUT"
    return
  fi

  xrandr --query 2>/dev/null | awk '
    / connected/ {
      if ($1 ~ /^eDP/ || $1 ~ /^EDP/ || $1 ~ /^LVDS/ || $1 ~ /^DSI/) {
        print $1
        exit
      }
      if (first == "") {
        first = $1
      }
    }
    END {
      if (first != "") {
        print first
      }
    }
  '
}

set_refresh_rate_xrandr() {
  local target_hz="$1"
  local output

  has_cmd xrandr || return 1
  xrandr --query >/dev/null 2>&1 || return 1

  output="$(detect_output_xrandr)"
  [[ -n "$output" ]] || return 1

  xrandr --output "$output" --rate "$target_hz" >/dev/null 2>&1 || return 1
  log "Set display refresh via xrandr: output=$output rate=${target_hz}Hz"
  return 0
}

set_refresh_rate_mutter() {
  local target_hz="$1"

  [[ -x "$REFRESH_HELPER" ]] || return 1
  command -v /usr/bin/python3 >/dev/null 2>&1 || return 1

  /usr/bin/python3 "$REFRESH_HELPER" --hz "$target_hz" --output "$REFRESH_OUTPUT" >/dev/null 2>&1 || return 1
  log "Set display refresh via Mutter DisplayConfig: output=${REFRESH_OUTPUT} rate=${target_hz}Hz"
  return 0
}

set_refresh_rate_gnome_randr() {
  local target_hz="$1"
  local output

  has_cmd gnome-randr || return 1

  if [[ "$REFRESH_OUTPUT" != "auto" ]]; then
    output="$REFRESH_OUTPUT"
  else
    output="$(gnome-randr query 2>/dev/null | awk '/ connected/{print $1; exit}')"
  fi

  [[ -n "$output" ]] || return 1

  gnome-randr modify "$output" --rate "$target_hz" >/dev/null 2>&1 || return 1
  log "Set display refresh via gnome-randr: output=$output rate=${target_hz}Hz"
  return 0
}

apply_refresh_rate_policy() {
  local source="$1"
  local target_hz
  local key

  target_hz="$(select_refresh_target "$source")"
  if ! is_positive_number "$target_hz"; then
    warn "Invalid refresh target '$target_hz'; expected number"
    return
  fi

  key="${source}:${target_hz}"
  if [[ -f "$REFRESH_STATE_FILE" ]] && [[ "$(cat "$REFRESH_STATE_FILE" 2>/dev/null || true)" == "$key" ]]; then
    return
  fi

  if set_refresh_rate_mutter "$target_hz" || set_refresh_rate_gnome_randr "$target_hz" || set_refresh_rate_xrandr "$target_hz"; then
    printf '%s\n' "$key" > "$REFRESH_STATE_FILE"
    return
  fi

  warn "Could not set display refresh to ${target_hz}Hz (install gnome-randr for GNOME Wayland, or use X11 xrandr)"
}

set_asus_profile() {
  local target="$1"
  if ! has_cmd asusctl; then
    warn "asusctl not found; skipping ASUS profile"
    return
  fi

  local current
  current="$(asusctl profile get 2>/dev/null | awk -F': ' '/Active profile/{print $2; exit}')"
  if [[ "$current" == "$target" ]]; then
    return
  fi

  if asusctl profile set "$target" >/dev/null 2>&1; then
    log "Set ASUS profile: $target"
  else
    warn "Failed to set ASUS profile to $target"
  fi
}

supergfx_active() {
  systemctl is-active --quiet supergfxd.service 2>/dev/null
}

run_supergfx() {
  if ! has_cmd supergfxctl; then
    return 127
  fi
  timeout -k 1s 5s supergfxctl "$@" 2>/dev/null
}

get_pending_action() {
  local action
  action="$(run_supergfx -p | tr -d '[:space:]' || true)"
  if [[ -z "$action" || "$(normalize "$action")" == "none" || "$(normalize "$action")" == "unknown" || "$(normalize "$action")" == "noactionrequired" ]]; then
    echo "none"
  else
    echo "$action"
  fi
}

get_pending_mode() {
  local mode
  mode="$(run_supergfx -P | tr -d '[:space:]' || true)"
  if [[ -z "$mode" || "$(normalize "$mode")" == "unknown" ]]; then
    echo "none"
  else
    echo "$mode"
  fi
}

notify_pending_logout() {
  local target="$1"
  local action="$2"
  local key
  key="${target}:${action}"

  if [[ -f "$NOTIFY_STATE_FILE" ]] && [[ "$(cat "$NOTIFY_STATE_FILE" 2>/dev/null || true)" == "$key" ]]; then
    return
  fi

  printf '%s\n' "$key" > "$NOTIFY_STATE_FILE"

  if has_cmd notify-send; then
    notify-send "Power mode pending" "GPU switch to ${target} is pending (${action}). Log out to complete transition." || true
  fi
}

clear_pending_notify_state() {
  rm -f "$NOTIFY_STATE_FILE" 2>/dev/null || true
}

supergfx_reported_mode() {
  if [[ -f "$REPORTED_MODE_FILE" ]]; then
    tr -d '[:space:]' < "$REPORTED_MODE_FILE"
    return
  fi
  echo "unknown"
}

cache_reported_mode() {
  local mode="$1"
  printf '%s\n' "$mode" > "$REPORTED_MODE_FILE"
}

mode_is_hybrid() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"hybrid"* ]]
}

mode_is_dgpu() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"asusmuxdgpu"* || "$value" == *"dgpu"* || "$value" == *"dedicated"* || "$value" == *"nvidia"* ]]
}

mode_is_integrated() {
  local value
  value="$(normalize "$1")"
  [[ "$value" == *"integrated"* || "$value" == "intel" ]]
}

find_nvidia_gpu_bdf() {
  local dev vendor class
  for dev in /sys/bus/pci/devices/*; do
    [[ -f "$dev/vendor" && -f "$dev/class" ]] || continue
    vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
    class="$(cat "$dev/class" 2>/dev/null || true)"
    if [[ "$vendor" == "0x10de" && "$class" == 0x03* ]]; then
      basename "$dev"
      return 0
    fi
  done
  return 1
}

dgpu_pci_present() {
  [[ -n "$(find_nvidia_gpu_bdf || true)" ]]
}

dgpu_runtimepm_suspended() {
  local bdf dev control status pstate
  bdf="$(find_nvidia_gpu_bdf || true)"
  [[ -n "$bdf" ]] || return 1

  dev="/sys/bus/pci/devices/$bdf"
  [[ -r "$dev/power/control" && -r "$dev/power/runtime_status" && -r "$dev/power_state" ]] || return 1

  control="$(cat "$dev/power/control" 2>/dev/null || true)"
  status="$(cat "$dev/power/runtime_status" 2>/dev/null || true)"
  pstate="$(cat "$dev/power_state" 2>/dev/null || true)"

  [[ "$control" == "auto" && "$status" == "suspended" && "$pstate" == D3* ]]
}

# Driver binding is read from sysfs on purpose: nvidia-smi would wake a runtime-suspended dGPU.
dgpu_driver_bound() {
  local bdf
  bdf="$(find_nvidia_gpu_bdf || true)"
  [[ -n "$bdf" && -L "/sys/bus/pci/devices/$bdf/driver" ]] || return 1
  [[ "$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver")")" == "nvidia" ]]
}

effective_gpu_class() {
  if ! dgpu_pci_present; then
    echo "integrated"
    return
  fi

  if ! dgpu_driver_bound; then
    echo "dgpu-pci-no-driver"
    return
  fi

  echo "dgpu"
}

print_dgpu_repair_hint() {
  if mode_is_integrated "$(supergfx_reported_mode)"; then
    cat <<'EOF'
hint: supergfxctl is in Integrated mode but the policy expects Hybrid.
hint: switch once (requests Hybrid and logs out within the 30 s supergfxd window):
  ~/.local/bin/g14-power-mode.sh apply --logout-on-pending yes
EOF
    return
  fi
  cat <<'EOF'
hint: dGPU device is missing from PCI tree while non-integrated mode is expected.
hint: try in terminal:
  sudo sh -c 'echo 1 > /sys/bus/pci/rescan'
  nvidia-smi -L
EOF
}

expected_gpu_class_from_policy() {
  local ppd="$1"
  local source="$2"

  if [[ "$GPU_POLICY" == "hybrid-only" ]]; then
    echo "hybrid"
  elif [[ "$ppd" == "performance" ]]; then
    echo "hybrid"
  elif [[ "$source" == "dc" && "$ppd" == "power-saver" ]]; then
    echo "integrated"
  else
    echo "hybrid"
  fi
}

is_gpu_consistent_with_expected() {
  local expected="$1"
  local effective
  effective="$(effective_gpu_class)"

  case "$expected" in
    integrated)
      [[ "$effective" == "integrated" ]] || dgpu_runtimepm_suspended
      ;;
    hybrid)
      [[ "$effective" == "dgpu" ]]
      ;;
    dgpu)
      [[ "$effective" == "dgpu" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

supported_gpu_modes() {
  run_supergfx -s \
    | tr -d '[]' \
    | tr ',' '\n' \
    | sed 's/^\s*//;s/\s*$//' \
    | sed '/^$/d'
}

select_mode_from_supported() {
  local desired_class="$1"
  local supported raw candidate normalized
  supported="$(supported_gpu_modes || true)"
  [[ -n "$supported" ]] || return 1

  if [[ "$desired_class" == "integrated" ]]; then
    for candidate in Integrated integrated Intel; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  elif [[ "$desired_class" == "hybrid" ]]; then
    for candidate in Hybrid hybrid AsusEgpu AsusMuxHybrid; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  else
    for candidate in AsusMuxDgpu Nvidia Dedicated; do
      normalized="$(normalize "$candidate")"
      while IFS= read -r raw; do
        [[ "$(normalize "$raw")" == "$normalized" ]] && { echo "$raw"; return 0; }
      done <<< "$supported"
    done
  fi

  return 1
}

set_gpu_mode() {
  local desired_class="$1"
  local logout_on_pending="$2"

  if [[ "${G14_SKIP_GPU_MODE:-0}" == "1" ]]; then
    log "Skipping GPU mode request (G14_SKIP_GPU_MODE=1)"
    return
  fi

  if ! has_cmd supergfxctl; then
    warn "supergfxctl not found; skipping GPU mode"
    return
  fi

  if ! supergfx_active; then
    warn "supergfxd inactive; skipping GPU mode"
    return
  fi

  local target current
  target="$(select_mode_from_supported "$desired_class" || true)"
  if [[ -z "$target" ]]; then
    warn "No supported GPU mode found for class: $desired_class"
    return
  fi

  local current_pending_action current_pending_mode
  current_pending_action="$(get_pending_action)"
  current_pending_mode="$(get_pending_mode)"
  if [[ "$current_pending_action" != "none" ]]; then
    if [[ "$(normalize "$current_pending_mode")" == "$(normalize "$target")" ]]; then
      warn "GPU mode '$target' is already pending and requires session action: $current_pending_action"
      if [[ "$logout_on_pending" != "yes" ]]; then
        notify_pending_logout "$target" "$current_pending_action"
      fi
      return
    fi
  else
    clear_pending_notify_state
  fi

  current="$(supergfx_reported_mode)"
  if [[ "$(normalize "$current")" == "$(normalize "$target")" ]]; then
    if is_gpu_consistent_with_expected "$desired_class"; then
      return
    fi
    warn "GPU reported mode already '$target' but effective state is inconsistent; re-requesting"
  fi

  if run_supergfx -m "$target" >/dev/null 2>&1; then
    log "Requested GPU mode: $target"
    cache_reported_mode "$target"
  else
    warn "Failed to request GPU mode: $target"
    return
  fi

  local pending_action
  pending_action="$(get_pending_action)"
  if [[ "$pending_action" != "none" ]]; then
    warn "GPU mode switch pending action: $pending_action"
    if [[ "$logout_on_pending" == "yes" ]]; then
      if has_cmd gnome-session-quit; then
        log "Logging out to complete GPU mode switch"
        gnome-session-quit --logout --no-prompt || true
      else
        warn "gnome-session-quit not found; please log out manually"
      fi
    else
      notify_pending_logout "$target" "$pending_action"
    fi
  else
    clear_pending_notify_state
  fi

  if ! is_gpu_consistent_with_expected "$desired_class"; then
    warn "GPU state not yet consistent with expected class '$desired_class' (reported=$(supergfx_reported_mode), effective=$(effective_gpu_class))"
    if [[ "$pending_action" == "none" && "$desired_class" != "integrated" && "$(effective_gpu_class)" == "integrated" ]] && ! dgpu_pci_present; then
      print_dgpu_repair_hint | while IFS= read -r line; do warn "$line"; done
    fi
  fi
}

get_ppd() {
  if ! has_cmd powerprofilesctl; then
    echo "unknown"
    return
  fi

  local current
  current="$(powerprofilesctl get 2>/dev/null || true)"
  case "$current" in
    power-saver|balanced|performance) echo "$current" ;;
    *) echo "unknown" ;;
  esac
}

apply_profile_mapping() {
  local logout_on_pending="$1"
  local source ppd
  source="$(get_power_source)"
  ppd="$(get_ppd)"

  if [[ "$ppd" == "unknown" ]]; then
    warn "Could not read power profile; skipping apply"
    return
  fi

  apply_cpu_policy "$ppd"

  local gpu_class
  gpu_class="$(expected_gpu_class_from_policy "$ppd" "$source")"

  case "$ppd" in
    performance) set_asus_profile "Performance" ;;
    power-saver) set_asus_profile "Quiet" ;;
    *) set_asus_profile "Balanced" ;;
  esac

  set_gpu_mode "$gpu_class" "$logout_on_pending"
  enforce_dgpu_runtimepm_auto
  apply_refresh_rate_policy "$source"
  log "Applied mapping: ppd=$ppd source=$source gpu_policy=$GPU_POLICY gpu_class=$gpu_class"
}

status() {
  local source profile ppd gfx effective expected consistent nvidia_bdf pending_action pending_mode requires_logout
  source="$(get_power_source)"
  profile="$(asusctl profile get 2>/dev/null | awk -F': ' '/Active profile/{print $2; exit}' || true)"
  ppd="$(get_ppd)"
  gfx="$(supergfx_reported_mode)"
  expected="$(expected_gpu_class_from_policy "$ppd" "$source")"
  effective="$(effective_gpu_class)"
  nvidia_bdf="$(find_nvidia_gpu_bdf || true)"
  pending_action="$(get_pending_action)"
  pending_mode="$(get_pending_mode)"
  if [[ "$pending_action" == "none" ]]; then
    requires_logout="no"
  else
    requires_logout="yes"
  fi
  if is_gpu_consistent_with_expected "$expected"; then
    consistent="yes"
  else
    consistent="no"
  fi

  cat <<EOF
power_source=$source
asus_profile=${profile:-unknown}
ppd=${ppd:-unknown}
gpu_mode_reported=$gfx
gpu_mode_effective=$effective
gpu_policy=$GPU_POLICY
gpu_mode_expected=$expected
gpu_mode_consistent=$consistent
nvidia_gpu_bdf=${nvidia_bdf:-none}
pending_action=$pending_action
pending_mode=$pending_mode
requires_logout=$requires_logout
EOF
}

watch_loop() {
  local last_source=""
  local last_ppd=""
  local last_tick
  last_tick="$(date +%s)"
  while true; do
    local now_source now_ppd now_tick tick_gap force_apply
    now_source="$(get_power_source)"
    now_ppd="$(get_ppd)"
    now_tick="$(date +%s)"
    tick_gap=$((now_tick - last_tick))
    force_apply="no"

    if (( tick_gap > 20 )); then
      force_apply="yes"
      log "Long wake gap detected (${tick_gap}s); re-applying mapping"
    fi

    if [[ "$force_apply" == "yes" || "$now_source" != "$last_source" || "$now_ppd" != "$last_ppd" ]]; then
      log "Change detected: source ${last_source:-unknown} -> $now_source, ppd ${last_ppd:-unknown} -> $now_ppd"
      apply_profile_mapping "no"
      last_source="$now_source"
      last_ppd="$now_ppd"
    fi
    last_tick="$now_tick"
    sleep 5
  done
}

usage() {
  cat <<'EOF'
Usage:
  g14-power-mode.sh apply [--logout-on-pending yes|no]
  g14-power-mode.sh status
  g14-power-mode.sh check
  g14-power-mode.sh watch

Notes:
  - Ubuntu top-right menu (powerprofilesctl) is the mode selector.
  - AC/DC auto-apply is handled by the user systemd service running watch.
  - status/check rely on effective hardware state and cached requested mode.
  - GPU policy: G14_GPU_POLICY or ~/.config/g14-power/gpu-policy = hybrid-only (default) | acdc.
  - Every supergfxctl Integrated<->Hybrid change needs a logout within 30 s of the request.
EOF
}

cmd="${1:-}"
shift || true

logout_on_pending="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logout-on-pending)
      logout_on_pending="${2:-no}"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$cmd" in
  apply)
    apply_profile_mapping "$logout_on_pending"
    ;;
  status)
    status
    ;;
  check)
    source="$(get_power_source)"
    ppd="$(get_ppd)"
    expected="$(expected_gpu_class_from_policy "$ppd" "$source")"
    if is_gpu_consistent_with_expected "$expected"; then
      echo "ok: gpu state consistent (expected=$expected reported=$(supergfx_reported_mode) effective=$(effective_gpu_class))"
    else
      echo "mismatch: expected=$expected reported=$(supergfx_reported_mode) effective=$(effective_gpu_class)"
      if [[ "$expected" != "integrated" && "$(effective_gpu_class)" == "integrated" ]] && ! dgpu_pci_present; then
        print_dgpu_repair_hint
      fi
      exit 2
    fi
    ;;
  watch)
    watch_loop
    ;;
  *)
    usage
    exit 1
    ;;
esac
