#!/bin/bash
# Installs nvidia-smi-powersafe as /usr/local/bin/nvidia-smi so that GNOME Shell (Vitals) and any other
# tool that loops nvidia-smi resolve the power-safe wrapper first. /usr/bin/nvidia-smi is untouched.
#
#   sudo bash install-nvidia-smi-powersafe.sh            install / update
#   bash install-nvidia-smi-powersafe.sh --check         show which nvidia-smi GNOME Shell resolves
#   sudo bash install-nvidia-smi-powersafe.sh --revert   remove the wrapper
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/configs/gnome/nvidia-smi-powersafe"
DEST="/usr/local/bin/nvidia-smi"
MARKER="nvidia-smi-powersafe"

check() {
  local shell_pid path resolved
  if [[ -x "$DEST" ]] && grep -q "$MARKER" "$DEST"; then
    echo "wrapper:   installed at $DEST"
  else
    echo "wrapper:   not installed"
  fi
  shell_pid="$(pgrep -x gnome-shell | head -1 || true)"
  if [[ -n "$shell_pid" ]]; then
    path="$(tr '\0' '\n' < "/proc/$shell_pid/environ" 2>/dev/null | sed -n 's/^PATH=//p')"
    resolved="$(PATH="$path" command -v nvidia-smi || true)"
    echo "gnome-shell resolves nvidia-smi to: ${resolved:-not found}"
  fi
  # the wrapper runs as "python3 /usr/local/bin/nvidia-smi ...", the stock binary as "/usr/bin/nvidia-smi ..."
  pgrep -a -f '^(\S*python3 )?/usr(/local)?/bin/nvidia-smi ' | cut -c1-80 | sed 's/^/running loop: /' || true
}

case "${1:-}" in
  --check)
    check
    exit 0
    ;;
  --revert)
    [[ "$EUID" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
    if [[ -f "$DEST" ]] && grep -q "$MARKER" "$DEST"; then
      rm -f "$DEST"
      echo "Removed $DEST"
    else
      echo "No wrapper at $DEST"
    fi
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: $0 [--check|--revert]" >&2
    exit 1
    ;;
esac

[[ "$EUID" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -f /usr/bin/nvidia-smi ]] || { echo "/usr/bin/nvidia-smi not found; install the NVIDIA driver first" >&2; exit 1; }
if [[ -e "$DEST" ]] && ! grep -q "$MARKER" "$DEST"; then
  echo "$DEST exists and is not this wrapper; refusing to overwrite" >&2
  exit 1
fi

install -m 755 "$SRC" "$DEST"
echo "Installed $DEST (wraps /usr/bin/nvidia-smi)"
echo ""
echo "Next: bash $ROOT_DIR/configs/gnome/vitals-setup.sh   # re-enables GPU sensors through the wrapper"
