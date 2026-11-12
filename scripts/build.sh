#!/bin/zsh
# mdr.app을 빌드합니다. 사용법: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Debug}"
xcodegen generate --quiet
xcodebuild -project mdr.xcodeproj -scheme mdr -configuration "$config" \
  -derivedDataPath build -quiet build
echo "build/Build/Products/$config/mdr.app"
