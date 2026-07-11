#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
identity="${DEVELOPER_ID_APPLICATION:?Set a Developer ID Application identity in DEVELOPER_ID_APPLICATION.}"
notary_profile="${NOTARYTOOL_PROFILE:?Set a notarytool Keychain profile in NOTARYTOOL_PROFILE.}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/IrbisKVM/Info.plist")"
derived_data="$project_root/build/ReleaseDerivedData"
artifact_directory="$project_root/build/release"
dmg="$artifact_directory/IrbisKVM-$version.dmg"

if [[ -e "$dmg" ]]; then
  echo "Refusing to overwrite existing artifact: $dmg" >&2
  exit 1
fi

xcodebuild -quiet \
  -project "$project_root/IrbisKVM.xcodeproj" \
  -scheme IrbisKVM \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$derived_data/Build/Products/Release/IrbisKVM.app"
codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/IrbisKVM.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/IrbisKVM.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$artifact_directory"
hdiutil create -quiet \
  -volname "IrbisKVM $version" \
  -srcfolder "$stage" \
  -format UDZO \
  "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --verbose=2 "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
shasum -a 256 "$dmg"

echo "Notarized release artifact: $dmg"
