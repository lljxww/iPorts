#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
configuration="${1:-release}"
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    native_architecture=arm64
else
    native_architecture="$(uname -m)"
fi
architecture="${2:-$native_architecture}"
case "$configuration" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release] [universal|arm64|x86_64]\n' "$0" >&2; exit 1 ;;
esac
case "$architecture" in
    universal) architecture_flags=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) architecture_flags=(--arch "$architecture") ;;
    *) printf 'Unknown architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

swift build -c "$configuration" "${architecture_flags[@]}"
bin_dir="$(swift build -c "$configuration" "${architecture_flags[@]}" --show-bin-path)"
mkdir -p "$repo_dir/build"
staging_dir="$(mktemp -d "$repo_dir/build/.iPorts-$architecture.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/iPorts.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/iPorts" "$app_dir/Contents/MacOS/iPorts"
actual_architectures="$(xcrun lipo -archs "$app_dir/Contents/MacOS/iPorts")"
if [[ "$architecture" == universal ]]; then
    case "$actual_architectures" in
        'arm64 x86_64'|'x86_64 arm64') ;;
        *) printf 'Expected arm64 and x86_64, found: %s\n' "$actual_architectures" >&2; exit 1 ;;
    esac
elif [[ "$actual_architectures" != "$architecture" ]]; then
    printf 'Expected %s executable, found: %s\n' "$architecture" "$actual_architectures" >&2
    exit 1
fi
printf 'Executable architectures: %s\n' "$actual_architectures"
cp resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${IPORTS_VERSION:-}" ]]; then
    python3 scripts/release.py set-version "$app_dir/Contents/Info.plist" "$IPORTS_VERSION"
fi
sparkle_framework="$repo_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$sparkle_framework"
mkdir -p "$app_dir/Contents/Frameworks"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
# Keep native packages native, including Sparkle's executable helpers. Re-sign only changed binaries.
if [[ "$architecture" != universal ]]; then
    while IFS= read -r -d '' sparkle_binary; do
        if file "$sparkle_binary" | /usr/bin/grep -q 'Mach-O universal binary'; then
            xcrun lipo "$sparkle_binary" -thin "$architecture" -output "$sparkle_binary.thin"
            mv "$sparkle_binary.thin" "$sparkle_binary"
            codesign --force --sign - "$sparkle_binary"
        fi
    done < <(find "$app_dir/Contents/Frameworks" -type f -print0)
    codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework"
fi
resource_bundle="$bin_dir/iPorts_PortsCore.bundle"
test -d "$resource_bundle"
cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
cp resources/APPLE-ARTWORK.md "$app_dir/Contents/Resources/APPLE-ARTWORK.md"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_dir/Contents/Resources/SPARKLE-LICENSE.txt"
xcrun swift scripts/create-icon.swift "$repo_dir/build/AppIcon.iconset"
iconutil --convert icns "$repo_dir/build/AppIcon.iconset" --output "$app_dir/Contents/Resources/AppIcon.icns"
plutil -lint "$app_dir/Contents/Info.plist"
# Ad-hoc builds cannot enable Library Validation when loading Sparkle's separate signature.
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
archive="$repo_dir/build/iPorts-macos-$architecture.zip"
ditto -c -k --keepParent "$app_dir" "$staging_dir/iPorts.zip"
final_app="$repo_dir/build/iPorts.app"
if [[ -e "$final_app" ]]; then
    mv "$final_app" "$staging_dir/previous.app"
fi
if ! mv "$app_dir" "$final_app"; then
    if [[ -e "$staging_dir/previous.app" ]]; then mv "$staging_dir/previous.app" "$final_app"; fi
    exit 1
fi
mv "$staging_dir/iPorts.zip" "$archive"
printf 'App: %s\nArchive: %s\n' "$final_app" "$archive"
