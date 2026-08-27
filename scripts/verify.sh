#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$project_root/build"

xcodebuild \
  -project "$project_root/IrbisKVM.xcodeproj" \
  -scheme IrbisKVM \
  -configuration Debug \
  -derivedDataPath "$build_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcrun swiftc \
  -parse-as-library \
  "$project_root/IrbisKVM/Protocol/CH9329Protocol.swift" \
  "$project_root/IrbisKVM/Protocol/HIDTextMap.swift" \
  "$project_root/tools/CH9329ProtocolSelfTest.swift" \
  -o "$build_root/CH9329ProtocolSelfTest"

"$build_root/CH9329ProtocolSelfTest"
