#!/usr/bin/env bash
set -euo pipefail
: "${GALA_BUILD_DIR:?Gala Engine sets this}"
: "${GALA_ARTIFACT_DIR:?Gala Engine sets this}"
xcodegen generate
xcodebuild -project MBBooks.xcodeproj -scheme MBBooks -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$GALA_BUILD_DIR/DerivedData" \
  -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  -jobs "${GALA_JOBS:-2}" CODE_SIGNING_ALLOWED=NO build
stage="$(mktemp -d "$GALA_BUILD_DIR/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" "$GALA_ARTIFACT_DIR"
ditto "$GALA_BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/MBBooks.app" "$stage/Payload/MBBooks.app"
(cd "$stage" && /usr/bin/zip -qry "$GALA_ARTIFACT_DIR/MBBooks-unsigned.ipa" Payload)
