#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${1:-iphoneos}"
case "$sdk" in
  iphoneos) destination='generic/platform=iOS'; arch='arm64';;
  iphonesimulator) destination='generic/platform=iOS Simulator'; arch="$(uname -m)";;
  *) echo 'Use iphoneos or iphonesimulator' >&2; exit 2;;
esac
mkdir -p logs output
{
  xcodebuild -version
  xcrun --sdk "$sdk" --show-sdk-version
  uname -m
} > "logs/environment-$sdk.txt" 2>&1
xcodebuild build \
  -project NativeDiagnostics/NativeDiagnostics.xcodeproj \
  -scheme NativeDiagnostics -configuration Release \
  -sdk "$sdk" -destination "$destination" \
  -derivedDataPath "build/$sdk" \
  ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  2>&1 | tee "logs/build-$sdk.log"
if [[ "$sdk" == iphoneos ]]; then
  app="build/iphoneos/Build/Products/Release-iphoneos/NativeDiagnostics.app"
  test -f "$app/Info.plist"
  test -f "$app/NativeDiagnostics"
  file "$app/NativeDiagnostics" | tee logs/device-binary.txt
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" >> logs/device-binary.txt
  package_dir="$(mktemp -d)"
  trap 'rm -rf "$package_dir"' EXIT
  mkdir "$package_dir/Payload"
  ditto "$app" "$package_dir/Payload/NativeDiagnostics.app"
  target="$PWD/output/NativeDiagnostics-unsigned.ipa"
  (cd "$package_dir" && /usr/bin/zip -qry "$target" Payload)
  /usr/bin/unzip -t "$target"
  shasum -a 256 "$target" > logs/ipa-sha256.txt
fi
