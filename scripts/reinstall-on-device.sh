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

INSTALLED=".build/installed.mobileprovision"   # profile of the build actually on the iPad
if [[ $FORCE == 0 && -f "$INSTALLED" ]]; then
  left_h=$(( ( $(expiry_epoch "$INSTALLED") - $(date +%s) ) / 3600 ))
  (( left_h > RENEW_WITHIN_HOURS )) && { say "skip: profile valid ${left_h}h more"; exit 0; }
fi
# A client currently streaming from this Mac: per client, connects minus
# disconnects > 0 since the host last started (a late timeout of an old session
# can be the newest line; a host crash leaves no disconnect), or host stream
# stats written in the last 2 minutes.
session_active() {
  local open recent_stats ts
  open=$(grep -hE "Parsec: Started|#[0-9]+ (connected|disconnected)\.$" ~/.parsec/log.txt 2>/dev/null \
    | awk '/Parsec: Started/{delete n; next} {c=$NF; who=$(NF-1); if (c=="connected.") n[who]++; else n[who]--} END{t=0; for (k in n) if (n[k]>0) t++; print t}')
  recent_stats=$(tail -200 ~/.parsec/log.txt 2>/dev/null | grep -E "\] \[0\] FPS:" | tail -1 | sed -E 's/^\[. ([0-9-]+ [0-9:]+)\].*/\1/')
  if [[ -n "$recent_stats" ]]; then
    ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$recent_stats" +%s 2>/dev/null || echo 0)
    (( $(date +%s) - ts < 120 )) && { echo "recent-stats"; return 0; }
  fi
  (( ${open:-0} > 0 )) && { echo "open=$open"; return 0; }
  return 1
}
if [[ $FORCE == 0 ]] && why=$(session_active); then say "skip: Parsec session in progress ($why)"; exit 0; fi
# Never ship a half-edited working tree to the iPad unattended.
if [[ $FORCE == 0 ]] && ! git diff --quiet HEAD -- OpenParsec OpenParsec.xcodeproj 2>/dev/null; then
  say "skip: uncommitted changes in the app sources"; exit 0
fi
if ! xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" | grep -v unavailable | grep -qE "available|connected"; then
  say "skip: ${DEVICE} not reachable"; exit 0
fi

say "start: reinstall on ${DEVICE}"
# Xcode keeps reusing a still-valid profile, so set ours aside to make it
# issue a fresh 7-day one. Never delete it: if the build fails (e.g. no Apple
# ID in Xcode → "No Accounts"), it is put back and the app keeps working.
STASH=".build/profile-stash"
restore_profiles() { mv "$STASH"/*.mobileprovision "$PROFILES"/ 2>/dev/null && say "restored set-aside profile(s)"; return 0; }
restore_profiles   # a previous run died mid-way (sleep, kill): never lose its stash
mkdir -p "$STASH"
trap restore_profiles EXIT
for f in "$PROFILES"/*.mobileprovision; do
  [[ -f "$f" ]] || continue
  if security cms -D -i "$f" 2>/dev/null | grep -q "<string>${APP_ID}</string>"; then
    mv "$f" "$STASH/"; say "set aside expiring profile $(basename "$f")"
  fi
done
notify() { osascript -e "display notification \"$1\" with title \"OpenParsec reinstall\"" 2>/dev/null || true; }
RUN=".build/reinstall-run.log"
if ! xcodebuild -project OpenParsec.xcodeproj -scheme OpenParsec -configuration Debug \
     -destination "platform=iOS,name=${DEVICE}" -derivedDataPath .build/DeviceDD \
     DEVELOPMENT_TEAM=CY4R3PK7Z3 PRODUCT_BUNDLE_IDENTIFIER=com.extnddos.OpenParsec.dev \
     -allowProvisioningUpdates build -quiet >"$RUN" 2>&1; then
  cat "$RUN" >>"$LOG"
  if grep -q "No Accounts" "$RUN"; then
    say "FAILED: no Apple ID in Xcode (Xcode → Settings → Accounts) — cannot renew signing"
    notify "Signing not renewed: add your Apple ID in Xcode → Settings → Accounts"
  else
    notify "Build failed — see .build/reinstall.log"
  fi
  say "FAILED (see above)"; exit 1
fi
# The build takes minutes: a session may have started meanwhile.
if [[ $FORCE == 0 ]] && why=$(session_active); then say "skip install: Parsec session started during build ($why)"; exit 0; fi
if ! xcrun devicectl device install app --device "${DEVICE}" "$APP" >"$RUN" 2>&1; then
  cat "$RUN" >>"$LOG"; notify "Install on ${DEVICE} failed — see .build/reinstall.log"
  say "FAILED (see above)"; exit 1
fi
cp "$APP/embedded.mobileprovision" "$INSTALLED"
trap - EXIT; rm -rf "$STASH"
say "ok: profile now valid until $(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)"
