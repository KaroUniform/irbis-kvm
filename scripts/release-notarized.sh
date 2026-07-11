#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
identity="${DEVELOPER_ID_APPLICATION:?Set a Developer ID Application identity in DEVELOPER_ID_APPLICATION.}"
notary_profile="${NOTARYTOOL_PROFILE:?Set a notarytool Keychain profile in NOTARYTOOL_PROFILE.}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/IrbisKVM/Info.plist")"
derived_data="$project_root/build/ReleaseDerivedData"
artifact_directory="$project_root/build/release"
dmg="$artifact_directory/IrbisKVM-$version.dmg"

notarize_and_wait() {
  local artifact="$1"
  local output
  local submission_id

  if ! output="$(xcrun notarytool submit "$artifact" --keychain-profile "$notary_profile" --wait 2>&1)"; then
    printf '%s\n' "$output" >&2
    submission_id="$(printf '%s\n' "$output" | awk '$1 == "id:" { print $2; exit }')"
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" >&2 || true
    fi
    return 1
  fi

  printf '%s\n' "$output"
  [[ "$output" == *"status: Accepted"* ]] || {
    echo "Notarization did not finish with status: Accepted" >&2
    return 1
  }
}

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
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
signature_details="$(codesign -dvv "$app" 2>&1)"
[[ "$signature_details" == *"runtime"* && "$signature_details" == *"Timestamp="* ]] || {
  echo "Signed app is missing hardened runtime or secure timestamp" >&2
  exit 1
}

workspace="$(mktemp -d "${TMPDIR:-/tmp}/IrbisKVM.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT

app_zip="$workspace/IrbisKVM.app.zip"
ditto -c -k --keepParent "$app" "$app_zip"
notarize_and_wait "$app_zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"

dmg_stage="$workspace/dmg"
mkdir "$dmg_stage"
ditto "$app" "$dmg_stage/IrbisKVM.app"
ln -s /Applications "$dmg_stage/Applications"

mkdir -p "$artifact_directory"
hdiutil create -quiet \
  -volname "IrbisKVM $version" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  "$dmg"
hdiutil verify "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --verbose=2 "$dmg"

notarize_and_wait "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --verbose=2 "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
shasum -a 256 "$dmg"

echo "Notarized release artifact: $dmg"
