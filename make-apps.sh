#!/bin/bash
# Builds into dist/:
#   LunaSender.app    (universal, macOS 13+ — the MacBook side)
#   LunaReceiver.app  (universal, runs back to macOS 10.15 for old iMacs)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.3.0
BUILD=$(date +%Y%m%d%H%M)

swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release

rm -rf dist
mkdir -p dist

# --- Signing identity -------------------------------------------------------
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
  echo "Signing as: $IDENTITY"
else
  IDENTITY="-"
  echo "NOTE: no Developer ID Application identity; signing ad-hoc." >&2
  echo "      The apps still work — the first launch on another Mac needs" >&2
  echo "      right-click -> Open (Gatekeeper)." >&2
fi

sign() {  # sign <path>
  # --timestamp (Apple's timestamp server, needs network): notarization
  # requires a secure timestamp on every signature.
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$1"
  else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"
  fi
}

plist_head() {  # plist_head <executable> <package type> <min os>
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$1</string>
    <key>CFBundlePackageType</key><string>$2</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>$3</string>
PL
}

# --- LunaSender.app -----------------------------------------------------------
SENDER=dist/LunaSender.app
mkdir -p "$SENDER/Contents/MacOS"
cp "$BIN/LunaSender" "$SENDER/Contents/MacOS/LunaSender"
{
  plist_head LunaSender APPL 13.0
  cat <<PL
    <key>CFBundleIdentifier</key><string>local.luna.sender</string>
    <key>CFBundleName</key><string>LunaSender</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Luna streams your display to another Mac on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_lunax._tcp</string></array>
</dict>
</plist>
PL
} > "$SENDER/Contents/Info.plist"
sign "$SENDER"

# --- LunaReceiver.app ---------------------------------------------------------
RECEIVER=dist/LunaReceiver.app
mkdir -p "$RECEIVER/Contents/MacOS"
cp "$BIN/LunaReceiver" "$RECEIVER/Contents/MacOS/LunaReceiver"
{
  plist_head LunaReceiver APPL 10.15
  cat <<PL
    <key>CFBundleIdentifier</key><string>local.luna.receiver</string>
    <key>CFBundleName</key><string>LunaReceiver</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Luna receives a display stream from another Mac on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_lunax._tcp</string></array>
</dict>
</plist>
PL
} > "$RECEIVER/Contents/Info.plist"
sign "$RECEIVER"

codesign --verify --strict "$SENDER" && codesign --verify --strict "$RECEIVER"

# --- Notarize --------------------------------------------------------------
# Notarized apps open on other Macs without the right-click -> Open step.
# One-time credential setup: signing/README.md. Skip with LUNA_NO_NOTARIZE=1.
NOTARY_PROFILE=${LUNA_NOTARY_PROFILE:-luna}
if [ "$IDENTITY" != "-" ] && [ -z "${LUNA_NO_NOTARIZE:-}" ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notarizing with keychain profile '$NOTARY_PROFILE'…"
    submission_id() {  # submission_id <app> -> submit a zip of it, print the id
      local zip="dist/.$(basename "$1" .app).zip"
      rm -f "$zip"
      ditto -c -k --keepParent "$1" "$zip"
      xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --output-format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
    }
    sender_id=$(submission_id "$SENDER")
    receiver_id=$(submission_id "$RECEIVER")
    for pair in "$SENDER:$sender_id" "$RECEIVER:$receiver_id"; do
      app=${pair%%:*}; id=${pair##*:}
      status=$(xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
      if [ "$status" != "Accepted" ]; then
        echo "ERROR: notarization of $app: $status. Details:" >&2
        echo "       xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
      fi
      xcrun stapler staple -q "$app"
      echo "  $app: notarized and stapled ($id)"
    done
  else
    echo "NOTE: no notarytool keychain profile '$NOTARY_PROFILE' — not notarizing." >&2
    echo "      The apps still work; the first launch on another Mac needs" >&2
    echo "      right-click -> Open. Setup: signing/README.md." >&2
  fi
fi

echo
echo "Built:"
echo "  dist/LunaSender.app    (the Mac whose display is extended, macOS 13+)"
echo "  dist/LunaReceiver.app  (copy to the Mac acting as the monitor, macOS 10.15+)"

# --- Deploy the sender to /Applications when a copy lives there -------------
# Developer ID signing keeps the Screen Recording grant stable across
# rebuilds; the one-time switch from an ad-hoc build orphans the old grant,
# so reset it when the team changes.
APP=/Applications/LunaSender.app
if [ -d "$APP" ] && [ -z "${LUNA_NO_DEPLOY:-}" ]; then
  old_team=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/{print $2}')
  new_team=$(codesign -dvv "$SENDER" 2>&1 | awk -F= '/^TeamIdentifier/{print $2}')
  old_hash=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')
  new_hash=$(codesign -dvvv "$SENDER" 2>&1 | awk -F= '/^CDHash/{print $2}')
  if [ "$old_hash" != "$new_hash" ]; then
    pkill -x LunaSender 2>/dev/null || true
    rm -rf "$APP"
    ditto "$SENDER" "$APP"
    echo
    echo "Deployed to /Applications (new build)."
    if [ "$old_team" != "$new_team" ]; then
      tccutil reset ScreenCapture local.luna.sender >/dev/null 2>&1 || true
      echo "Signing identity changed: macOS will ask for Screen Recording once on next launch."
    fi
  else
    echo
    echo "/Applications/LunaSender.app is already this exact build."
  fi
fi
