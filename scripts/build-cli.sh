#!/bin/zsh
# mdr CLI(Go)를 빌드합니다. 사용법: scripts/build-cli.sh [test]
#   결과: build/cli/mdr-<os>-<arch> (macOS arm64·amd64, Linux amd64·arm64). 모두 정적 바이너리입니다.
#   test를 주면 빌드 전에 Go 테스트를 돌립니다.
set -euo pipefail
cd "$(dirname "$0")/../cli"
if [ "${1:-}" = test ]; then
  mise exec -- go vet ./...
  mise exec -- go test -race -timeout 180s ./...
fi
out=../build/cli
mkdir -p "$out"
for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
  os="${target%/*}" arch="${target#*/}"
  GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 mise exec -- go build -trimpath -ldflags "-s -w" -o "$out/mdr-$os-$arch" .
  echo "build/cli/mdr-$os-$arch"
done
