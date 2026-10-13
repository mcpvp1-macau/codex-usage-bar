#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/dist}"
app_dir="$output_dir/Codex Kimi Usage Bar.app"
iconset_parent="$(mktemp -d /tmp/codex-kimi-iconset.XXXXXX)"
iconset_dir="$iconset_parent/AppIcon.iconset"
trap 'rm -rf -- "$iconset_parent"' EXIT
sdk_path="/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk"
swift_compiler="/Library/Developer/CommandLineTools/usr/bin/swiftc"

if [[ -e "$app_dir" ]]; then
  echo "Build target already exists: $app_dir" >&2
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
"$swift_compiler" \
  -parse-as-library \
  -sdk "$sdk_path" \
  -target arm64-apple-macos14.0 \
  -O \
  "$project_dir"/Sources/CodexUsageBar/*.swift \
  -o "$app_dir/Contents/MacOS/CodexUsageBar"

cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp -R "$project_dir/Resources/Assets.xcassets/AppIcon.appiconset" "$iconset_dir"
iconutil -c icns -o "$app_dir/Contents/Resources/AppIcon.icns" "$iconset_dir"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
