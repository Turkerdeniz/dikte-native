#!/bin/zsh
set -euo pipefail

IDENTITY="Dikte Native Local Signing"
ROOT_DIR="${0:A:h:h}"
BUILD_DIR="${DIKTE_BUILD_DIR:-$ROOT_DIR/build}"
STAGE_DIR="$(mktemp -d /private/tmp/dikte-native-build.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/Dikte.app"
CONTENTS="$APP_DIR/Contents"
OUTPUT_ZIP="$BUILD_DIR/Dikte.app.zip"
SWIFT_CACHE="/private/tmp/dikte-native-swift-cache"
CLANG_CACHE="/private/tmp/dikte-native-clang-cache"
WORKSPACE_STATE="$ROOT_DIR/.build/workspace-state.json"

# SwiftPM stores the package root and binary-artifact path as absolute values.
# A moved checkout otherwise keeps compiling against its former location.
if [[ -f "$WORKSPACE_STATE" ]] && ! grep -Fq "\"location\" : \"$ROOT_DIR\"" "$WORKSPACE_STATE"; then
  swift package --package-path "$ROOT_DIR" clean
  rm -f "$WORKSPACE_STATE"
fi

security find-identity -v -p codesigning | rg -F "\"$IDENTITY\"" >/dev/null || {
  print -u2 "Required signing identity is missing: $IDENTITY"
  print -u2 "Run scripts/setup-signing.sh once. Ad-hoc signing is intentionally disabled."
  exit 1
}

env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_CACHE" \
  swift test --package-path "$ROOT_DIR" --arch arm64 -j 1
env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_CACHE" \
  swift build --package-path "$ROOT_DIR" -c release --arch arm64 -j 1

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$ROOT_DIR/.build/arm64-apple-macosx/release/DikteNative" "$CONTENTS/MacOS/DikteNative"
ditto "$ROOT_DIR/.build/arm64-apple-macosx/release/DikteNative_DikteNative.bundle" \
  "$CONTENTS/Resources/DikteNative_DikteNative.bundle"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
xcrun actool "$ROOT_DIR/Resources/Assets.xcassets" --compile "$CONTENTS/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$STAGE_DIR/asset-info.plist"
[[ -f "$CONTENTS/Resources/AppIcon.icns" ]] || { print -u2 "AppIcon.icns was not generated."; exit 1; }
ditto "$ROOT_DIR/.build/artifacts/dikte native/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework" \
  "$CONTENTS/Frameworks/whisper.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/DikteNative"
xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$CONTENTS/Frameworks/whisper.framework" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$CONTENTS/Frameworks/whisper.framework" 2>/dev/null || true

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$CONTENTS/Frameworks/whisper.framework"
codesign --force --options runtime --timestamp=none --entitlements "$ROOT_DIR/Resources/Dikte.entitlements" --sign "$IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -d --entitlements :- "$APP_DIR" 2>&1 | rg -q 'com.apple.security.device.audio-input' || {
  print -u2 "Signed app is missing the audio-input entitlement."
  exit 1
}
VAD_MODEL="$CONTENTS/Resources/DikteNative_DikteNative.bundle/ggml-silero-v6.2.0.bin"
[[ -f "$VAD_MODEL" ]] || { print -u2 "Bundled Silero VAD model is missing."; exit 1; }
[[ "$(shasum -a 256 "$VAD_MODEL" | awk '{print $1}')" == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]] || {
  print -u2 "Bundled Silero VAD checksum does not match."
  exit 1
}

ARCHS="$(lipo -archs "$CONTENTS/MacOS/DikteNative")"
[[ "$ARCHS" == "arm64" ]] || { print -u2 "Unexpected executable architectures: $ARCHS"; exit 1; }
mkdir -p "$BUILD_DIR"
rm -f "$OUTPUT_ZIP"
# Resource forks/FinderInfo are not part of the signed bundle and make a freshly
# extracted archive fail strict code-sign verification. Keep the ZIP portable by
# omitting AppleDouble metadata from the release artifact.
ditto -c -k --keepParent --norsrc "$APP_DIR" "$OUTPUT_ZIP"
print "$OUTPUT_ZIP"
