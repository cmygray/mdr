#!/bin/zsh
# 완료 조건을 스냅숏과 측정값으로 확인합니다. 결과는 output/verify/에 남습니다.
# 사용법: scripts/verify.sh   (먼저 scripts/build.sh로 빌드해 두어야 합니다)
set -uo pipefail
cd "$(dirname "$0")/.."
out="$PWD/output/verify"
mkdir -p "$out" tmp
size=1000x690

echo "== 1. fixture 세 개: 라이트·다크 스냅숏과 조판 측정"
for name in 01-korean-handoff 02-english-readme 03-images-typesetting; do
  for mode in light dark; do
    scripts/snap.sh "fixtures/$name.md" "$out/$name-$mode.png" -size $size -appearance $mode \
      -metrics "$out/$name-$mode.json" 2>/dev/null
  done
done

echo "== 2. 요소별 스냅숏(표, 코드 블록, 이미지, 인용문, 각주)"
scripts/snap.sh fixtures/01-korean-handoff.md "$out/element-table.png" -size $size -scrollTo "구조" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/element-wide-table.png" -size $size -scrollTo "V-A" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/element-image.png" -size $size -scrollTo "V-B" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/element-blockquote.png" -size $size -scrollTo "I 서론" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/element-list.png" -size $size -scrollTo "III-C" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/element-footnotes.png" -size $size -scrollTo "감사의" 2>/dev/null

echo "== 3. 코드 블록 가로 스크롤"
scripts/snap.sh fixtures/02-english-readme.md "$out/code-scroll-before.png" -size $size -scrollTo "Getting Started" 2>/dev/null
scripts/snap.sh fixtures/02-english-readme.md "$out/code-scroll-after.png" -size $size -scrollTo "Getting Started" \
  -codeScroll 400 -metrics "$out/code-scroll.json" 2>/dev/null

echo "== 4. 토큰 파일을 고치면 실행 중에 다시 그리는지"
tokens="$PWD/tmp/verify-tokens.json"
cp Sources/MdrKit/Resources/tokens.json "$tokens"
MDR_TOKENS="$tokens" scripts/snap.sh fixtures/01-korean-handoff.md "$out/hot-reload-before.png" -size $size \
  -metrics "$out/hot-reload-before.json" 2>/dev/null
# 앱이 뜬 지 1.5초 뒤에 글자 크기와 배경색을 바꿉니다. 스냅숏은 3초 뒤에 찍습니다.
( sleep 1.5
  python3 - "$tokens" <<'PY'
import json, sys
path = sys.argv[1]
tokens = json.load(open(path))
tokens["baseSize"] = 20
tokens["colors"]["light"]["background"] = "#FFF1CC"
json.dump(tokens, open(path, "w"), ensure_ascii=False, indent=2)
PY
) &
MDR_TOKENS="$tokens" scripts/snap.sh fixtures/01-korean-handoff.md "$out/hot-reload-after.png" -size $size \
  -wait 3 -metrics "$out/hot-reload-after.json" 2>/dev/null
wait

echo "== 5. 문서별 스크롤 위치 기억"
scripts/snap.sh fixtures/03-images-typesetting.md "$out/scroll-memory-1-saved.png" -size $size -persist YES \
  -scrollTo "IV-C" -metrics "$out/scroll-memory-1.json" 2>/dev/null
scripts/snap.sh fixtures/03-images-typesetting.md "$out/scroll-memory-2-restored.png" -size $size -persist YES \
  -metrics "$out/scroll-memory-2.json" 2>/dev/null
# 다른 문서는 영향을 받지 않아야 합니다.
scripts/snap.sh fixtures/02-english-readme.md "$out/scroll-memory-3-other.png" -size $size -persist YES \
  -metrics "$out/scroll-memory-3.json" 2>/dev/null

echo "== 6. 메뉴 동작: 글자 크게 두 번, 본문 폭 넓게 한 번, 사이드바 가리기"
scripts/snap.sh fixtures/03-images-typesetting.md "$out/menu-zoom-wide-nosidebar.png" -size $size \
  -perform "zoomIn:,zoomIn:,widenMeasure:,toggleSidebar:" -wait 1.2 -metrics "$out/menu.json" 2>/dev/null

echo "== 7. 목차에서 제목을 고르면 그 자리로 이동"
scripts/snap.sh fixtures/03-images-typesetting.md "$out/outline-jump.png" -size $size -outlineRow 21 \
  -metrics "$out/outline-jump.json" 2>/dev/null

echo "== 요약"
python3 - "$out" <<'PY'
import json, sys, os
out = sys.argv[1]
def load(name):
    return json.load(open(os.path.join(out, name)))
ok = True
def check(label, condition, detail):
    global ok
    ok = ok and bool(condition)
    print(("  통과  " if condition else "  실패  ") + label + " — " + detail)

for name in ["01-korean-handoff", "02-english-readme", "03-images-typesetting"]:
    m = load(f"{name}-light.json")
    cpl = m["charactersPerLine"]
    low, high = (35, 45) if m["script"] == "hangul" else (60, 75)
    if cpl["count"] >= 10:
        check(f"{name} 한 줄 글자 수", low <= cpl["median"] <= high,
              f'{m["script"]}, 중앙값 {cpl["median"]}자 (10%~90%: {cpl["p10"]}~{cpl["p90"]}자, {cpl["count"]}줄), 목표 {low}~{high}자')
    else:
        print(f'  참고  {name} 한 줄 글자 수 — 들여쓰지 않은 본문 줄이 {cpl["count"]}줄뿐이라 판정하지 않음')
    check(f"{name} 낱말 안 줄바꿈", m["lineBreaksInsideWord"] == 0, f'{m["lineBreaksInsideWord"]}건 / 줄바꿈 {m["lineBreaks"]}건')
    ratio = m["bodyLineHeight"] / m["bodySize"]
    check(f"{name} 행간", m["measuredBodyLineHeights"] == [m["bodyLineHeight"]],
          f'토큰 {m["bodyLineHeight"]}pt({ratio:.2f}배), 실제 배치 {m["measuredBodyLineHeights"]}pt')
    inset = m["textContainerInset"][0]
    check(f"{name} 본문 폭과 가운데 정렬", abs(m["viewWidth"] - 2 * inset - m["measure"]) < 1,
          f'창 안 폭 {m["viewWidth"]}pt = 좌우 여백 {inset}pt × 2 + 본문 {m["measure"]}pt')
    dark = load(f"{name}-dark.json")
    check(f"{name} 다크 테마", dark["scheme"] == "dark", f'scheme={dark["scheme"]}')

c = load("code-scroll.json")["codeBlock"]
check("코드 블록 가로 스크롤", c["contentWidth"] > c["visibleWidth"] and c["scrolledTo"] > 0,
      f'내용 폭 {c["contentWidth"]:.0f}pt > 보이는 폭 {c["visibleWidth"]:.0f}pt, {c["scrolledTo"]:.0f}pt만큼 스크롤됨')

before, after = load("hot-reload-before.json"), load("hot-reload-after.json")
check("토큰 즉시 반영", before["bodySize"] == 16 and after["bodySize"] == 20 and after["tokenReloads"] >= 1,
      f'실행 중 다시 읽은 횟수 {after["tokenReloads"]}, 본문 크기 {before["bodySize"]}pt → {after["bodySize"]}pt (앱을 다시 시작하지 않음)')

s1, s2, s3 = load("scroll-memory-1.json"), load("scroll-memory-2.json"), load("scroll-memory-3.json")
check("스크롤 위치 기억", s1["topCharacterIndex"] > 0 and s1["topCharacterIndex"] == s2["topCharacterIndex"],
      f'저장한 위치 {s1["topCharacterIndex"]}("{s1["topHeading"]}"), 다시 열었을 때 {s2["topCharacterIndex"]}("{s2["topHeading"]}")')
check("스크롤 위치는 문서별", s3["topCharacterIndex"] == 0, f'다른 문서의 위치 {s3["topCharacterIndex"]}')
base, menu = load("03-images-typesetting-light.json"), load("menu.json")
check("메뉴: 글자 크기", menu["fontScale"] == 1.125 and menu["bodySize"] == 18,
      f'배율 {menu["fontScale"]}, 본문 {base["bodySize"]}pt → {menu["bodySize"]}pt')
check("메뉴: 본문 폭", menu["measureScale"] == 1.125 and abs(menu["measure"] - base["measure"] * 1.125 * 1.125) <= 1,
      f'배율 {menu["measureScale"]}, 본문 폭 {base["measure"]}pt → {menu["measure"]}pt (글자 크기 배율 포함)')
check("메뉴: 사이드바 가리기", menu["sidebarCollapsed"] and menu["viewWidth"] > base["viewWidth"],
      f'본문 영역 폭 {base["viewWidth"]}pt → {menu["viewWidth"]}pt')
jump = load("outline-jump.json")
check("목차 이동", jump["outlineRowTitle"] != "" and jump["topHeading"] == jump["outlineRowTitle"],
      f'목차 22번째 줄 "{jump["outlineRowTitle"]}" → 화면 맨 위 절 "{jump["topHeading"]}" (목차 {jump["outlineCount"]}줄)')
print("전체 결과:", "통과" if ok else "실패 있음")
sys.exit(0 if ok else 1)
PY
