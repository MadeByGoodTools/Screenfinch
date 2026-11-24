#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
destination=${1:-"$root/build"}
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)
stage=$(mktemp -d "$destination/.screenfinch.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Screenfinch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Screenfinch.icns" "$root/Resources/ScreenfinchStatusTemplate.pdf" \
    "$root/Resources/GoodTools.png" "$app/Contents/Resources/"
sdk=$(xcrun --sdk macosx --show-sdk-path)
swift_flags=()
if [[ ${SCREENFINCH_MENU_TEST:-${DISPLAYDESK_MENU_TEST:-0}} == 1 ]]; then
    swift_flags+=(-D MENU_REGRESSION)
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.screenfinch.menutest' "$app/Contents/Info.plist"
fi
for cpu in ${SCREENFINCH_ARCHS:-${DISPLAYDESK_ARCHS:-arm64 x86_64}}; do
    case "$cpu" in arm64|x86_64) ;; *) echo "Unsupported build architecture: $cpu" >&2; exit 1 ;; esac
    mkdir -p "$stage/$cpu"
    for source in "$root"/Sources/*.m; do
        object=$(basename "$source" .m)
        xcrun clang -target "$cpu-apple-macos13" -isysroot "$sdk" -fobjc-arc -fblocks -O2 \
            -I "$root/Sources" -c "$source" -o "$stage/$cpu/$object.o"
    done
    xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -parse-as-library -O -whole-module-optimization -module-name Screenfinch \
        -sdk "$sdk" -target "$cpu-apple-macos13.0" -import-objc-header "$root/Sources/Native.h" \
        "$root"/Sources/*.swift "$stage/$cpu"/*.o -framework IOKit -framework Carbon \
        -framework AppKit -framework CoreGraphics -framework ColorSync -framework ScreenCaptureKit \
        -o "$stage/Screenfinch-$cpu"
done
xcrun lipo -create "$stage"/Screenfinch-* -output "$app/Contents/MacOS/Screenfinch"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
target="$destination/Screenfinch.app"
if [[ -e "$target" ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)
    signed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    [[ "$bundle_id" == "$signed_id" ]] || { echo "Another app already occupies the destination." >&2; exit 1; }
    mv "$target" "$stage/previous.app"
fi
if ! mv "$app" "$target"; then
    [[ ! -d "$stage/previous.app" ]] || mv "$stage/previous.app" "$target"
    exit 1
fi
echo "$target"
