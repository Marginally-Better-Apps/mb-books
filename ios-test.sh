#!/usr/bin/env bash
set -euo pipefail
: "${GALA_BUILD_DIR:?Gala Engine sets this}"
xcodegen generate
# Unit tests cover the EPUB engine; UI tests drive the library and reader with a generated EPUB 3.4 book.
destination="${MB_TEST_DESTINATION:-$(python3 scripts/pick-simulator.py)}"
# Boot ahead of time so first-launch setup on a fresh simulator doesn't eat into UI test timeouts.
if [[ "$destination" =~ id=([0-9A-F-]+) ]]; then
  xcrun simctl bootstatus "${BASH_REMATCH[1]}" -b >/dev/null
fi
results="$GALA_BUILD_DIR/TestResults.xcresult"
rm -rf "$results"
xcodebuild -project MBBooks.xcodeproj -scheme MBBooks -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$GALA_BUILD_DIR/DerivedData" \
  -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  -resultBundlePath "$results" \
  -parallel-testing-enabled NO \
  -jobs "${GALA_JOBS:-2}" CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS="${MB_WARNINGS_AS_ERRORS:-NO}" test
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$GALA_BUILD_DIR/DerivedData/Build/Products/Debug-iphonesimulator/MBBooks.app/Info.plist" \
  | /usr/bin/grep -qx 'com.mbbooks.MBBooks'
