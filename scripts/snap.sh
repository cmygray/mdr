#!/bin/zsh
# mdr를 자동화 모드로 띄워 스냅숏을 찍습니다. 사용법: scripts/snap.sh FILE OUT.png [-이름 값 ...]
# 예: scripts/snap.sh fixtures/01-korean-handoff.md tmp/a.png -appearance dark -scrollTo "구조"
# 20초 안에 끝나지 않으면 강제로 끝냅니다.
set -uo pipefail
cd "$(dirname "$0")/.."
app="${MDR_APP:-build/Build/Products/Debug/mdr.app}/Contents/MacOS/mdr"
file="$1"; out="$2"; shift 2
"$app" "${file:A}" -snapshot "${out:A}" -exit YES -ApplePersistenceIgnoreState YES "$@" &
pid=$!
( sleep 20; kill -9 $pid 2>/dev/null ) &
killer=$!
wait $pid; code=$?
kill $killer 2>/dev/null
exit $code
