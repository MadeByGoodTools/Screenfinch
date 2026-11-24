#!/bin/bash
set -euo pipefail
if [[ $# != 2 || ! -d "$1/Contents/MacOS" ]]; then
    echo 'Usage: package.sh <Screenfinch.app> <output-directory>' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
app=$(cd "$1" && pwd)
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" == "Screenfinch" ]]
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
codesign --verify --strict --all-architectures "$app"
architectures=" $(xcrun lipo -archs "$app/Contents/MacOS/Screenfinch") "
if [[ "$architectures" != *" arm64 "* || "$architectures" != *" x86_64 "* ]]; then
    echo 'The release must contain Apple silicon and Intel executables.' >&2
    exit 1
fi
command -v dmgbuild >/dev/null || { echo 'Install dmgbuild 1.6.5 to build the Finder disk image.' >&2; exit 1; }
mkdir -p "$2"
destination=$(cd "$2" && pwd)
stage=$(mktemp -d "$destination/.screenfinch-package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root"
ditto "$app" "$stage/root/Screenfinch.app"
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool NO "$stage/components.plist"
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" --ownership recommended \
    --identifier ca.goodtools.screenfinch --version "$version" --install-location /Applications \
    "$stage/Screenfinch-component.pkg"
installer="$stage/Good Tools Installer.pkg"
productbuild --distribution "$here/Installer/distribution.xml" --resources "$here/Installer/Resources" \
    --package-path "$stage" "$installer"
name="GoodTools-Installer-Screenfinch-$version-macOS-Universal.dmg"
dmgbuild -s "$here/dmg-settings.py" -D "app=$app" -D "installer=$installer" \
    -D "background=$here/Background.png" "Screenfinch" "$stage/$name"
hdiutil verify "$stage/$name"
mv -f "$stage/$name" "$destination/$name"
echo "$destination/$name"
