#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash configs/power/root/install-root-cpu-helper.sh" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER_SRC="$ROOT_DIR/configs/power/root/g14-cpu-policy-apply.sh"
HELPER_DST="/usr/local/bin/g14-cpu-policy-apply.sh"

TARGET_USER="${SUDO_USER:-${1:-}}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Could not determine target user. Pass username as first argument." >&2
  exit 1
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "Unknown user: $TARGET_USER" >&2
  exit 1
fi

install -m 755 "$HELPER_SRC" "$HELPER_DST"

SUDOERS_FILE="/etc/sudoers.d/g14-power-cpu-policy"
cat > "$SUDOERS_FILE" <<EOF
$TARGET_USER ALL=(root) NOPASSWD: $HELPER_DST power-saver, $HELPER_DST balanced, $HELPER_DST performance
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

echo "Installed $HELPER_DST"
echo "Configured passwordless sudo for user '$TARGET_USER' on CPU policy helper"
echo "You can test with: sudo -n $HELPER_DST power-saver"
