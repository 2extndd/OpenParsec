#!/usr/bin/env bash
# Rebuild with a fresh 7-day Personal Team profile and reinstall on the paired
# iPad over USB or the same Wi-Fi. Run nightly by a LaunchAgent; it skips while
# the installed profile has more than 5 days left, when the iPad is unreachable,
# or while a Parsec client is connected to this Mac (installing would kill the
# app mid-session).
#   scripts/reinstall-on-device.sh [--force] [device-name]
set -euo pipefail
cd "$(dirname "$0")/.."
FORCE=0; [[ "${1:-}" == "--force" ]] && { FORCE=1; shift; }
DEVICE="${1:-${OPENPARSEC_DEVICE:-iPad (Igor)}}"
RENEW_WITHIN_HOURS="${OPENPARSEC_RENEW_WITHIN_HOURS:-120}"   # 7-day profile → renewed every ~2 days
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LOG=".build/reinstall.log"
APP=".build/DeviceDD/Build/Products/Debug-iphoneos/OpenParsec.app"
APP_ID="CY4R3PK7Z3.com.extnddos.OpenParsec.dev"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p .build
say() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
expiry_epoch() {  # expiration of a .mobileprovision (or the installed app's embedded one)
  local d; d=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || return 1
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s
}

if [[ $FORCE == 0 && -f "$APP/embedded.mobileprovision" ]]; then
  left_h=$(( ( $(expiry_epoch "$APP/embedded.mobileprovision") - $(date +%s) ) / 3600 ))
  (( left_h > RENEW_WITHIN_HOURS )) && { say "skip: profile valid ${left_h}h more"; exit 0; }
fi
# A client currently streaming from this Mac: the newest connected/disconnected
# line in the host log says "connected." → don't kill the app now.
last=$(grep -hE "#[0-9]+ (connected|disconnected)\.$" ~/.parsec/log.txt 2>/dev/null | tail -1 || true)
if [[ $FORCE == 0 && "$last" == *" connected." ]]; then say "skip: Parsec session in progress"; exit 0; fi
if ! xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" | grep -q "available"; then
  say "skip: ${DEVICE} not reachable"; exit 0
fi

say "start: reinstall on ${DEVICE}"
# Xcode keeps reusing a still-valid profile; drop ours so it issues a fresh 7-day one.
for f in "$PROFILES"/*.mobileprovision; do
  [[ -f "$f" ]] || continue
  if security cms -D -i "$f" 2>/dev/null | grep -q "<string>${APP_ID}</string>"; then
    rm -f "$f"; say "removed expiring profile $(basename "$f")"
  fi
done
if xcodebuild -project OpenParsec.xcodeproj -scheme OpenParsec -configuration Debug \
     -destination "platform=iOS,name=${DEVICE}" -derivedDataPath .build/DeviceDD \
     DEVELOPMENT_TEAM=CY4R3PK7Z3 PRODUCT_BUNDLE_IDENTIFIER=com.extnddos.OpenParsec.dev \
     -allowProvisioningUpdates build -quiet >>"$LOG" 2>&1 \
   && xcrun devicectl device install app --device "${DEVICE}" \
     .build/DeviceDD/Build/Products/Debug-iphoneos/OpenParsec.app >>"$LOG" 2>&1; then
  say "ok: profile now valid until $(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)"
else
  say "FAILED (see above)"; exit 1
fi
