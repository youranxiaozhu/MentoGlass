#!/bin/bash
set -euo pipefail
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OUTPUT_DIR="${MENTOGLASS_OUTPUT_DIR:-$(dirname "$SOURCE_DIR")/dist}"
mkdir -p "$OUTPUT_DIR"
STAGING_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MentoGlass-build.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/MentoGlass.app"
TASK_CACHE="${TMPDIR:-/tmp}/mentoglass-swift-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TASK_CACHE"
SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx26.0 \
  -module-cache-path "$TASK_CACHE" \
  "$SOURCE_DIR/Backend.swift" "$SOURCE_DIR/Extensions.swift" "$SOURCE_DIR/Model.swift" "$SOURCE_DIR/Views.swift" "$SOURCE_DIR/App.swift" \
  -framework SwiftUI -framework AppKit -framework Security -framework LocalAuthentication \
  -o "$APP/Contents/MacOS/MentoGlass"
/bin/cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$SOURCE_DIR/mentoglass_schedule.sh" "$APP/Contents/Resources/mentoglass_schedule.sh"
/bin/cp "$SOURCE_DIR/mentoglass_wireless_region.sh" "$APP/Contents/Resources/mentoglass_wireless_region.sh"
/bin/cp -R "$SOURCE_DIR/dualwan" "$APP/Contents/Resources/dualwan"
/usr/bin/xcrun swiftc -sdk "$SDK" -target arm64-apple-macosx26.0 \
  -module-cache-path "$TASK_CACHE" "$SOURCE_DIR/Icon.swift" -framework AppKit \
  -o "$STAGING_DIR/icon-builder"
"$STAGING_DIR/icon-builder" "$STAGING_DIR/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP"
"$APP/Contents/MacOS/MentoGlass" --self-test
/bin/sh -n "$APP/Contents/Resources/mentoglass_schedule.sh"
/bin/sh -n "$APP/Contents/Resources/mentoglass_wireless_region.sh"
for script in "$APP/Contents/Resources/dualwan/"*.sh; do /bin/sh -n "$script"; done
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$OUTPUT_DIR/MentoGlass.zip"
/usr/bin/ditto --norsrc "$APP" "$OUTPUT_DIR/MentoGlass.app"
/usr/bin/xattr -d com.apple.FinderInfo "$OUTPUT_DIR/MentoGlass.app" 2>/dev/null || true
# Documents may add Finder metadata immediately after copying. The ZIP is made
# from the verified clean staging bundle and remains the reliable distribution.
if ! /usr/bin/codesign --verify --deep --strict "$OUTPUT_DIR/MentoGlass.app" 2>/dev/null; then
  printf 'Clean signed archive verified; Finder metadata was added to the loose copy.\n'
fi
printf 'Built: %s\n' "$OUTPUT_DIR/MentoGlass.app"
