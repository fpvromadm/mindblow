#!/bin/bash
# Build MindBlow.app from the Swift package and install it in place.
# Always overwrites /Applications/MindBlow.app — the one canonical copy
# (what Spotlight finds); no app bundles are left inside the project.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="/Applications/MindBlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MindBlow "$APP/Contents/MacOS/MindBlow"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" >/dev/null 2>&1 || true

# Register with Launch Services so Spotlight picks up the fresh bundle at once
# instead of waiting for the folder scan to notice it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "Installed $APP"
echo "Run it with:  open $APP"
