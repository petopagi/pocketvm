#!/bin/zsh
# Builds PocketVM.app into ./build and ad-hoc signs it with the virtualization entitlement.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/PocketVM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PocketVM "$APP/Contents/MacOS/PocketVM"
cp Support/Info.plist "$APP/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Support/PocketVM.entitlements --options runtime "$APP"
echo "Built $APP"

# ./build.sh --install copies it to /Applications (quit PocketVM first).
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x PocketVM >/dev/null; then echo "Quit PocketVM first." >&2; exit 1; fi
  rm -rf /Applications/PocketVM.app
  ditto "$APP" /Applications/PocketVM.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PocketVM.app
  echo "Installed /Applications/PocketVM.app"
fi
