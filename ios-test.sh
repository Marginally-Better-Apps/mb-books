#!/usr/bin/env bash
set -euo pipefail
: "${GALA_BUILD_DIR:?Gala Engine sets this}"
xcodegen generate
# Compile the SwiftUI workspace against the simulator SDK without booting a device.
# Replace or extend this gate with XCTest when app behavior is added.
xcodebuild -project MBBooks.xcodeproj -scheme MBBooks -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$GALA_BUILD_DIR/DerivedData" \
  -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  -jobs "${GALA_JOBS:-2}" CODE_SIGNING_ALLOWED=NO build
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$GALA_BUILD_DIR/DerivedData/Build/Products/Debug-iphonesimulator/MBBooks.app/Info.plist" \
  | /usr/bin/grep -qx 'com.mbbooks.MBBooks'
