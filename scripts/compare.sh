#!/bin/zsh
# fixture마다 mdr와 QuickMD 화면을 찍어 output/compare/에 저장합니다.
#
#   scripts/compare.sh
#
# 결과(문서마다)
#   <문서>.mdr.png           mdr 화면(사이드바를 접음. QuickMD와 본문 폭 조건을 맞추기 위해서입니다)
#   <문서>.mdr-sidebar.png   mdr 화면(목차 사이드바를 연 기본 모습)
#   <문서>.quickmd.png       QuickMD 화면
#   <문서>.compare.png       mdr(사이드바 접음)와 QuickMD를 나란히 붙인 그림
#
# QuickMD 창을 찍으려면 이 스크립트를 실행하는 터미널 앱에 화면 기록 권한이 있어야 합니다
# (시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 기록). 권한이 없으면 mdr 화면만 저장하고
# 0이 아닌 값으로 끝납니다. mdr는 자기 창을 스스로 찍으므로 권한이 필요 없습니다.
set -uo pipefail
cd "$(dirname "$0")/.."
out="$PWD/output/compare"
mkdir -p "$out" tmp
[ -x tmp/shot ] && [ tmp/shot -nt scripts/shot.swift ] || swiftc -O scripts/shot.swift -o tmp/shot || exit 1
quickmd_id="pl.falami.studio.QuickMD"
fixtures=(01-korean-handoff 02-english-readme 03-images-typesetting)

can_capture=$(tmp/shot access)
if [ "$can_capture" != "yes" ]; then
  echo "화면 기록 권한이 없어 QuickMD 창은 찍지 못합니다. mdr 화면만 저장합니다." >&2
fi

for name in $fixtures; do
  file="$PWD/fixtures/$name.md"
  size="1000x690"

  if [ "$can_capture" = "yes" ]; then
    open -a QuickMD "$file"
    # 창이 뜨고 내용이 그려질 때까지 기다립니다.
    info=""
    for attempt in {1..50}; do
      info=$(tmp/shot window "$quickmd_id" 2>/dev/null) && break
      sleep 0.2
    done
    sleep 2.5
    info=$(tmp/shot window "$quickmd_id" 2>/dev/null)
    if [ -n "$info" ]; then
      window_id=${info%% *}
      rest=${info#* }
      size="${rest% *}x${rest#* }"
      screencapture -x -o -l "$window_id" "$out/$name.quickmd.png" || echo "QuickMD 창을 찍지 못했습니다: $name" >&2
    else
      echo "QuickMD 창을 찾지 못했습니다: $name" >&2
    fi
    # 다음 문서의 창과 섞이지 않게 QuickMD를 끝냅니다.
    tmp/shot quit "$quickmd_id"
    sleep 1
  fi

  # mdr는 QuickMD 창과 같은 크기로 찍습니다. 모양(라이트·다크)은 시스템 설정을 따릅니다.
  scripts/snap.sh "$file" "$out/$name.mdr.png" -size "$size" -appearance system -sidebar hide 2>/dev/null
  scripts/snap.sh "$file" "$out/$name.mdr-sidebar.png" -size "$size" -appearance system 2>/dev/null

  if [ -f "$out/$name.quickmd.png" ]; then
    tmp/shot compose "$out/$name.mdr.png" "$out/$name.quickmd.png" "$out/$name.compare.png" "mdr" "QuickMD"
  fi
done

ls -1 "$out"
[ "$can_capture" = "yes" ]
