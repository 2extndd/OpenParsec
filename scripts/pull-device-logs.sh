#!/usr/bin/env bash
# Pull OpenParsec diagnostics from a connected iPad into .build/device-logs/<timestamp>/.
#   scripts/pull-device-logs.sh [device-name-or-id] [bundle-id]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/{print $3; exit}')}"
BUNDLE="${2:-com.extnddos.OpenParsec.dev}"
[[ -n "$DEVICE" ]] || { echo "no paired device found" >&2; exit 2; }
OUT=".build/device-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/system"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source Documents --destination "$OUT" >/dev/null
xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
  --source . --destination "$OUT/system" >/dev/null 2>&1 || true
find "$OUT/system" -type f ! -iname '*OpenParsec*' -delete 2>/dev/null || true
echo "logs: $OUT"
ls -la "$OUT"
if [[ -f "$OUT/diagnostics.log" ]]; then
  echo "--- connect / disconnect / sdk summary ---"
  grep -E "connect-(attempt|failed|ok)|sdk-log|transport-|network-path|audio-|background-lifecycle event=did-enter" "$OUT/diagnostics.log" | tail -60
fi
