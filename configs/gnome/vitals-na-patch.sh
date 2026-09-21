#!/bin/bash
# Local patch for the GNOME Vitals extension: show "N/A" for a GPU value that nvidia-smi reports as
# unavailable, instead of silently keeping the last number in the panel.
#
# Vitals' _returnGpuValue() drops any non-numeric value, and the panel label then keeps its previous text.
# With the power-safe nvidia-smi wrapper the dGPU reports "[N/A]" while asleep, so without this patch the
# panel would keep showing the last real utilization. Passing null instead makes Vitals render "N/A"
# (values.js: _legible(null) -> 'N/A').
#
#   bash vitals-na-patch.sh            apply (idempotent)
#   bash vitals-na-patch.sh --check    report patched / unpatched
#   bash vitals-na-patch.sh --revert   restore the original line
#
# GNOME Shell on Wayland loads extension code once per session: log out and back in after applying.
# Extension updates overwrite the file; vitals-setup.sh re-applies the patch.
set -euo pipefail

MARKER="g14-vitals-na-patch"
ORIG='        if (format !== '"'"'string'"'"' \&\& isNaN(value))
            return;'
FILE=""
for dir in "$HOME/.local/share/gnome-shell/extensions/Vitals@CoreCoding.com" \
           /usr/share/gnome-shell/extensions/Vitals@CoreCoding.com; do
  [[ -f "$dir/sensors.js" ]] && { FILE="$dir/sensors.js"; break; }
done
[[ -n "$FILE" ]] || { echo "Vitals sensors.js not found" >&2; exit 1; }

is_patched() { grep -q "$MARKER" "$FILE"; }

has_original() {
  python3 - "$FILE" <<'PY'
import sys
s = open(sys.argv[1]).read()
needle = "        if (format !== 'string' && isNaN(value))\n            return;\n"
sys.exit(0 if s.count(needle) == 1 else 1)
PY
}

case "${1:-}" in
  --check)
    if is_patched; then echo "patched: $FILE"; else echo "unpatched: $FILE"; fi
    exit 0
    ;;
  --revert)
    if ! is_patched; then echo "not patched"; exit 0; fi
    python3 - "$FILE" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
new = "        if (format !== 'string' && isNaN(value))\n            value = null; // g14-vitals-na-patch: render N/A instead of keeping the last value\n"
old = "        if (format !== 'string' && isNaN(value))\n            return;\n"
assert new in s
open(p, 'w').write(s.replace(new, old, 1))
PY
    echo "Reverted $FILE (log out and back in to reload Vitals)"
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: $0 [--check|--revert]" >&2; exit 1
    ;;
esac

if is_patched; then
  echo "Already patched: $FILE"
  exit 0
fi
if ! has_original; then
  echo "sensors.js does not contain the expected _returnGpuValue() lines exactly once; Vitals version changed, patch not applied" >&2
  exit 2
fi
cp -n "$FILE" "$FILE.orig" 2>/dev/null || true
python3 - "$FILE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        if (format !== 'string' && isNaN(value))\n            return;\n"
new = "        if (format !== 'string' && isNaN(value))\n            value = null; // g14-vitals-na-patch: render N/A instead of keeping the last value\n"
open(p, 'w').write(s.replace(old, new, 1))
PY
echo "Patched $FILE (backup: $FILE.orig). Log out and back in to reload Vitals."
