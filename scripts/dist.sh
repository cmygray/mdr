#!/bin/zsh
# 다른 Mac에 옮길 mdr.app을 만듭니다. Release 빌드 → Developer ID 서명 → output/dist/mdr-<버전>.zip
#
#   scripts/dist.sh
#
# 서명 인증서는 키체인에서 "Developer ID Application"을 찾아 씁니다. 여러 개이거나 다른 것을 쓰려면
# MDR_SIGN_IDENTITY에 인증서 이름이나 SHA-1을 줍니다. 인증서 이름은 이 파일에 적지 않습니다.
#
# 공증(notarization)은 하지 않습니다. 그래서 이 zip은 scp나 rsync처럼 quarantine 표시가 붙지 않는 방법으로
# 옮길 때만 그대로 열립니다. 브라우저나 AirDrop으로 받으면 Gatekeeper가 막습니다.
# hardened runtime은 켭니다. 나중에 공증하게 되면 다시 서명하지 않아도 됩니다.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${MDR_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  found=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
  count=$(print -r -- "$found" | grep -c . || true)
  [ "$count" -ge 1 ] || { echo "키체인에 Developer ID Application 인증서가 없습니다." >&2; exit 1; }
  [ "$count" -eq 1 ] || { echo "Developer ID Application 인증서가 $count개입니다. MDR_SIGN_IDENTITY로 하나를 고르십시오." >&2; exit 1; }
  identity="$found"
fi

# 받는 Mac이 Apple Silicon이든 Intel이든 돌도록 두 아키텍처를 함께 빌드합니다(scripts/build.sh는 이 Mac의 것만 빌드합니다).
xcodegen generate --quiet
xcodebuild -project mdr.xcodeproj -scheme mdr -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO -quiet build
built="build/Build/Products/Release/mdr.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist")

# 빌드 결과는 그대로 두고 사본에 서명합니다.
stage="$PWD/tmp/dist"
rm -rf "$stage"; mkdir -p "$stage" output/dist
ditto "$built" "$stage/mdr.app"
codesign --force --options runtime --timestamp --sign "$identity" "$stage/mdr.app"
codesign --verify --deep --strict "$stage/mdr.app"

zip="output/dist/mdr-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$stage/mdr.app" "$zip"

# zip을 풀어 서명이 그대로인지 다시 봅니다.
rm -rf "$stage/unzipped"; mkdir -p "$stage/unzipped"
ditto -x -k "$zip" "$stage/unzipped"
codesign --verify --deep --strict "$stage/unzipped/mdr.app"

echo "$zip ($bundle_id $version, $(lipo -archs "$stage/unzipped/mdr.app/Contents/MacOS/mdr"), $(du -h "$zip" | cut -f1 | tr -d ' '))"
codesign -dv "$stage/unzipped/mdr.app" 2>&1 | grep -E '^(Identifier|Timestamp|Runtime Version|flags)|CodeDirectory' | sed 's/^/  /'
# 같은 번들 식별자의 사본이 여기저기 남으면 시스템이 mdr:// 링크를 넘길 앱을 헷갈릴 수 있습니다. zip만 남깁니다.
rm -rf "$stage"
