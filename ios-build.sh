#!/usr/bin/env bash
set -euo pipefail
: "${GALA_BUILD_DIR:?Gala Engine sets this}"
: "${GALA_ARTIFACT_DIR:?Gala Engine sets this}"
source scripts/version.sh
xcodegen generate
xcodebuild -project MBBooks.xcodeproj -scheme MBBooks -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$GALA_BUILD_DIR/DerivedData" \
  -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  -jobs "${GALA_JOBS:-2}" CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER" build
stage="$(mktemp -d "$GALA_BUILD_DIR/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" "$GALA_ARTIFACT_DIR"
ditto "$GALA_BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/MBBooks.app" "$stage/Payload/MBBooks.app"
(cd "$stage" && /usr/bin/zip -qry "$GALA_ARTIFACT_DIR/MBBooks-unsigned.ipa" Payload)

python3 scripts/validate-ipa.py "$GALA_ARTIFACT_DIR/MBBooks-unsigned.ipa" "$APP_VERSION" "$APP_BUILD_NUMBER"
(cd "$GALA_ARTIFACT_DIR" && shasum -a 256 MBBooks-unsigned.ipa > MBBooks-unsigned.ipa.sha256)
python3 - "$GALA_ARTIFACT_DIR/build-info.json" <<'INFO'
import json, os, subprocess, sys
info = {
    "version": os.environ["APP_VERSION"],
    "build": os.environ["APP_BUILD_NUMBER"],
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "signed": False,
}
with open(sys.argv[1], "w") as output:
    json.dump(info, output, indent=2)
    output.write("\n")
INFO
