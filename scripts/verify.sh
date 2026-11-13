#!/bin/zsh
# 완료 조건을 스냅숏과 측정값으로 확인합니다. 결과는 output/verify/에 남습니다.
#
#   scripts/build.sh && scripts/verify.sh
#
# 이전 결과를 지우고 시작하고, 스냅숏 실행이 하나라도 실패하면 전체를 실패로 봅니다.
# 그래서 옛 결과 파일이 남아 통과로 보이는 일이 없습니다. 판정 요약은 output/verify/SUMMARY.txt에도 남습니다.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p output/verify tmp
find output/verify -type f -delete
out="$PWD/output/verify"
log="$out/snap.log"
size=1000x690
failed_snaps=0
[ -x tmp/shot ] && [ tmp/shot -nt scripts/shot.swift ] || swiftc -O scripts/shot.swift -o tmp/shot || exit 1

# 스냅숏 하나를 찍습니다. 실패하거나 결과 파일이 없으면 기록해 둡니다.
snap() {
  local file="$1" png="$2"
  shift 2
  if ! scripts/snap.sh "$file" "$png" "$@" >> "$log" 2>&1 || [ ! -s "$png" ]; then
    echo "  스냅숏 실패: ${png:t}" | tee -a "$log"
    failed_snaps=$((failed_snaps + 1))
  fi
}

echo "== 1. fixture 세 개: 라이트·다크 스냅숏과 조판 측정"
for name in 01-korean-handoff 02-english-readme 03-images-typesetting; do
  for mode in light dark; do
    snap "fixtures/$name.md" "$out/$name-$mode.png" -size $size -appearance $mode -metrics "$out/$name-$mode.json"
  done
done

echo "== 2. 요소별 스냅숏(표, 넓은 표와 가로 스크롤, 이미지, 인용문, 목록, 각주)"
snap fixtures/01-korean-handoff.md "$out/element-table.png" -size $size -scrollTo "구조"
snap fixtures/03-images-typesetting.md "$out/element-wide-table.png" -size $size -scrollTo "V-A"
snap fixtures/03-images-typesetting.md "$out/element-wide-table-scrolled.png" -size $size -scrollTo "V-A" \
  -tableScroll 10000 -metrics "$out/table-scroll.json"
snap fixtures/03-images-typesetting.md "$out/element-image.png" -size $size -scrollTo "V-B"
snap fixtures/03-images-typesetting.md "$out/element-image-2.png" -size $size -scrollTo "V-C"
snap fixtures/03-images-typesetting.md "$out/element-image-3.png" -size $size -scrollTo "V-D"
snap fixtures/03-images-typesetting.md "$out/element-blockquote.png" -size $size -scrollTo "I 서론"
snap fixtures/03-images-typesetting.md "$out/element-list.png" -size $size -scrollTo "III-C"
snap fixtures/03-images-typesetting.md "$out/element-footnotes.png" -size $size -scrollTo "감사의"

echo "== 3. 코드 블록 가로 스크롤"
snap fixtures/02-english-readme.md "$out/code-scroll-before.png" -size $size -scrollTo "Getting Started"
snap fixtures/02-english-readme.md "$out/code-scroll-after.png" -size $size -scrollTo "Getting Started" \
  -codeScroll 10000 -metrics "$out/code-scroll.json"

echo "== 4. 토큰 파일을 고치면 실행 중에 다시 그리는지"
tokens="$PWD/tmp/verify-tokens.json"
cp Sources/MdrKit/Resources/tokens.json "$tokens"
export MDR_TOKENS="$tokens"
snap fixtures/01-korean-handoff.md "$out/hot-reload-before.png" -size $size -metrics "$out/hot-reload-before.json"
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
snap fixtures/01-korean-handoff.md "$out/hot-reload-after.png" -size $size -wait 3 -metrics "$out/hot-reload-after.json"
wait

echo "== 4-2. 토큰 파일에 오류가 있으면 알리고 직전 값을 유지하는지"
( sleep 1.5; print -r -- '{ "baseSize": "크게" }' > "$tokens" ) &
snap fixtures/01-korean-handoff.md "$out/hot-reload-error.png" -size $size -wait 3 -metrics "$out/hot-reload-error.json"
wait
unset MDR_TOKENS

echo "== 4-3. 문서 파일이 바뀌면 읽던 자리를 지키며 다시 그리는지"
doc="$PWD/tmp/verify-doc.md"
cp fixtures/03-images-typesetting.md "$doc"
( sleep 1.5; print -r -- $'\n\n## 새로 붙인 절\n\n실행 중에 덧붙인 문단입니다.' >> "$doc" ) &
snap "$doc" "$out/document-reload.png" -size $size -scrollTo "IV-C" -wait 3 -metrics "$out/document-reload.json"
wait

echo "== 4-4. 줄바꿈 전략 대조: 어절 단위(기본) / 시스템 표준 / 전략 없음"
for strategy in standard none; do
  print -r -- "{\"body\": {\"lineBreak\": \"$strategy\"}}" > "tmp/verify-linebreak-$strategy.json"
  export MDR_TOKENS="$PWD/tmp/verify-linebreak-$strategy.json"
  snap fixtures/03-images-typesetting.md "$out/linebreak-$strategy.png" -size $size -metrics "$out/linebreak-$strategy.json"
done
unset MDR_TOKENS

echo "== 5. 문서별 스크롤 위치 기억"
# 먼저 맨 위로 옮긴 채 닫아 저장된 자리를 0으로 만듭니다. 그래야 이전 실행이 남긴 값으로 통과하지 않습니다.
snap fixtures/03-images-typesetting.md "$out/scroll-memory-0-reset.png" -size $size -persist YES -scrollFraction 0 \
  -metrics "$out/scroll-memory-0.json"
snap fixtures/03-images-typesetting.md "$out/scroll-memory-1-saved.png" -size $size -persist YES \
  -scrollTo "IV-C" -metrics "$out/scroll-memory-1.json"
snap fixtures/03-images-typesetting.md "$out/scroll-memory-2-restored.png" -size $size -persist YES \
  -metrics "$out/scroll-memory-2.json"
# 다른 문서는 영향을 받지 않아야 합니다.
snap fixtures/02-english-readme.md "$out/scroll-memory-3-other.png" -size $size -persist YES \
  -metrics "$out/scroll-memory-3.json"

echo "== 6. 메뉴 동작: 글자 크게 두 번, 본문 폭 넓게 한 번, 사이드바 가리기"
snap fixtures/03-images-typesetting.md "$out/menu-zoom-wide-nosidebar.png" -size $size \
  -perform "zoomIn:,zoomIn:,widenMeasure:,toggleSidebar:" -wait 1.2 -metrics "$out/menu.json"

echo "== 7. 목차에서 제목을 고르면 그 자리로 이동"
snap fixtures/03-images-typesetting.md "$out/outline-jump.png" -size $size -outlineRow 21 -metrics "$out/outline-jump.json"

echo "== 요약"
python3 - "$out" "$failed_snaps" <<'PY' | tee "$out/SUMMARY.txt"
import json, os, subprocess, sys, datetime, statistics
out, failed_snaps = sys.argv[1], int(sys.argv[2])
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
# 결과 폴더(output/)는 이 스크립트가 바꾸므로 빼고 봅니다.
dirty = subprocess.run(["git", "status", "--porcelain", "--", ".", ":!output"], capture_output=True, text=True).stdout.strip() != ""
print(f"검증 시각 {datetime.datetime.now():%Y-%m-%d %H:%M}, 커밋 {commit}{' + 커밋하지 않은 변경' if dirty else ''}")

def load(name):
    return json.load(open(os.path.join(out, name)))

def pixel(name, x, y):
    result = subprocess.run(["tmp/shot", "pixel", os.path.join(out, name), str(x), str(y)], capture_output=True, text=True)
    return [float(value) for value in result.stdout.split()]

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and bool(condition)
    print(("  통과  " if condition else "  실패  ") + label + " — " + detail)

check("스냅숏 실행", failed_snaps == 0, f"실패 {failed_snaps}건 (자세한 내용은 snap.log)")

expected = {
    # 원문에서 센 값: 이미지 문법, 코드 울타리 쌍, 표, 인용문 문단, 각주 정의
    "01-korean-handoff": dict(imageCount=0, codeBlockCount=0, tableCount=1, quoteParagraphCount=0, footnoteCount=0),
    "02-english-readme": dict(imageCount=0, codeBlockCount=3, tableCount=0, quoteParagraphCount=0, footnoteCount=0),
    "03-images-typesetting": dict(imageCount=3, codeBlockCount=0, tableCount=1, quoteParagraphCount=1, footnoteCount=17),
}

for name in ["01-korean-handoff", "02-english-readme", "03-images-typesetting"]:
    m = load(f"{name}-light.json")
    print(f"{name} ({m['script']})")

    cpl = m["charactersPerLine"]
    low, high = (35, 45) if m["script"] == "hangul" else (60, 75)
    if cpl["count"] >= 10:
        check("한 줄 글자 수", low <= cpl["median"] <= high and low <= cpl["p10"] and cpl["p90"] <= high,
              f'중앙값 {cpl["median"]}자, 10%~90% 구간 {cpl["p10"]}~{cpl["p90"]}자, 최대 {cpl["max"]}자 ({cpl["count"]}줄), 목표 {low}~{high}자')
    else:
        print(f'  참고  한 줄 글자 수 — 들여쓰지 않은 본문 줄이 {cpl["count"]}줄뿐이라 판정하지 않음(문서가 대부분 목록)')

    body, everything, table = m["bodyLineBreaks"], m["allLineBreaks"], m["tableLineBreaks"]
    check("낱말 안 줄바꿈(본문·목록·인용문·각주)", everything["insideWord"] == 0 and everything["breaks"] > 0,
          f'{everything["insideWord"]}건 / 줄바꿈 {everything["breaks"]}건 (그중 본문 {body["breaks"]}건), 줄보다 긴 낱말 때문에 끊긴 것 {everything["forcedByLongWord"]}건')
    if m["tableCount"]:
        check("낱말 안 줄바꿈(표 칸)", table["insideWord"] == 0 and table["breaks"] > 0,
              f'{table["insideWord"]}건 / 줄바꿈 {table["breaks"]}건, 칸보다 긴 낱말 때문에 끊긴 것 {table["forcedByLongWord"]}건')

    ratio = m["bodyLineHeight"] / m["bodySize"]
    low_ratio, high_ratio = (1.6, 1.75) if m["script"] == "hangul" else (1.5, 1.75)
    check("행간", m["measuredBodyLineHeights"] == [m["bodyLineHeight"]] and low_ratio <= ratio <= high_ratio,
          f'실제 배치된 줄 높이 {m["measuredBodyLineHeights"]}pt = 글자 크기 {m["bodySize"]}pt의 {ratio:.2f}배')

    # 실제로 배치된 줄의 왼쪽 끝과 가장 긴 줄의 폭으로 판정합니다.
    left, widest, measure, view = m["bodyLeft"], m["bodyMaxLineWidth"], m["measure"], m["viewWidth"]
    right = view - left - measure
    check("본문 폭 제한", 0.9 * measure <= widest <= measure + 0.5,
          f'가장 긴 줄 {widest}pt ≤ 본문 폭 {measure}pt (본문 영역 {view}pt)')
    check("가운데 정렬", abs(left - right) <= 1 and left > 0,
          f'배치된 줄의 왼쪽 여백 {left}pt, 오른쪽 여백 {right}pt')

    sizes = {}
    for heading in m["headings"]:
        sizes.setdefault(heading["level"], []).append(heading)
    levels = sorted(level for level in sizes if level <= 4)
    scale_ok, parts = True, []
    for upper, lower in zip(levels, levels[1:]):
        r = sizes[upper][0]["size"] / sizes[lower][0]["size"]
        scale_ok = scale_ok and lower == upper + 1 and 1.17 <= r <= 1.27
        parts.append(f'h{upper} {sizes[upper][0]["size"]}pt ÷ h{lower} {sizes[lower][0]["size"]}pt = {r:.2f}')
    if len(levels) >= 2:
        check("제목 modular scale(1.2~1.25배)", scale_ok, ", ".join(parts))
    spaced = [h for h in m["headings"] if h["gapAbove"] >= 0]
    check("제목 위 여백이 아래보다 큼", spaced and all(h["gapAbove"] > h["gapBelow"] for h in spaced),
          f'제목 {len(spaced)}개 모두 위 > 아래 (위 중앙값 {statistics.median(h["gapAbove"] for h in spaced):.0f}pt, 아래 중앙값 {statistics.median(h["gapBelow"] for h in spaced):.0f}pt)')

    counts = {key: m[key] for key in expected[name]}
    check("블록 개수가 원문과 같음", counts == expected[name],
          f'이미지 {m["imageCount"]}, 코드 블록 {m["codeBlockCount"]}, 표 {m["tableCount"]}, 인용문 문단 {m["quoteParagraphCount"]}, 각주 {m["footnoteCount"]}')
    check("목차", m["outlineCount"] > 0, f'{m["outlineCount"]}줄')

    # 테마는 스냅숏의 픽셀로 봅니다. 본문 영역 오른쪽 여백의 한 점입니다.
    light_pixel, dark_pixel = pixel(f"{name}-light.png", 0.97, 0.5), pixel(f"{name}-dark.png", 0.97, 0.5)
    check("라이트·다크 테마", len(light_pixel) == 3 and len(dark_pixel) == 3 and min(light_pixel) > 0.9 and max(dark_pixel) < 0.2,
          f'배경 픽셀 라이트 {light_pixel}, 다크 {dark_pixel}')

print("문서 공통")
reference = load("03-images-typesetting-light.json")["allLineBreaks"]
standard, none = load("linebreak-standard.json")["allLineBreaks"], load("linebreak-none.json")["allLineBreaks"]
check("어절 단위 줄바꿈의 효과", none["insideWord"] > 50 and standard["insideWord"] > 0 and reference["insideWord"] == 0,
      f'낱말 안 줄바꿈: 전략 없음 {none["insideWord"]}건, 시스템 표준 {standard["insideWord"]}건, mdr 기본값 {reference["insideWord"]}건 (예: {standard["samples"][:2]})')

c = load("code-scroll.json")["codeBlock"]
limit = c["contentWidth"] - c["visibleWidth"]
check("코드 블록 가로 스크롤", limit > 0 and abs(c["scrolledTo"] - limit) < 1,
      f'내용 폭 {c["contentWidth"]:.0f}pt, 보이는 폭 {c["visibleWidth"]:.0f}pt, 끝까지({c["scrolledTo"]:.0f}pt) 스크롤됨')

t = load("table-scroll.json")["tableBlock"]
limit = t["contentWidth"] - t["visibleWidth"]
check("넓은 표 가로 스크롤", limit > 0 and abs(t["scrolledTo"] - limit) < 1 and t["visibleWidth"] > load("table-scroll.json")["measure"],
      f'표 폭 {t["contentWidth"]:.0f}pt, 보이는 폭 {t["visibleWidth"]:.0f}pt(본문 폭 {load("table-scroll.json")["measure"]}pt보다 넓게 사용), 끝까지({t["scrolledTo"]:.0f}pt) 스크롤됨')

before, after = load("hot-reload-before.json"), load("hot-reload-after.json")
after_pixel = pixel("hot-reload-after.png", 0.97, 0.5)
check("토큰 즉시 반영", before["bodySize"] == 16 and after["bodySize"] == 20 and after["tokenReloads"] >= 1
      and len(after_pixel) == 3 and after_pixel[2] < 0.85,
      f'실행 중 다시 읽은 횟수 {after["tokenReloads"]}, 본문 크기 {before["bodySize"]}pt → {after["bodySize"]}pt, 바뀐 배경 픽셀 {after_pixel} (앱을 다시 시작하지 않음)')

error = load("hot-reload-error.json")
band = pixel("hot-reload-error.png", 0.6, 0.992)
check("토큰 오류 처리", error["tokenError"] != "" and error["bodySize"] == 20 and len(band) == 3 and band[0] > 0.9 and band[1] < 0.5,
      f'오류 메시지 "{error["tokenError"]}", 본문 크기는 직전 값 {error["bodySize"]}pt 유지, 창 아래 띠 픽셀 {band}')

reloaded, original = load("document-reload.json"), load("03-images-typesetting-light.json")
check("문서 변경 반영", reloaded["outlineCount"] == original["outlineCount"] + 1 and reloaded["topHeading"].startswith("IV-C"),
      f'목차 {original["outlineCount"]}줄 → {reloaded["outlineCount"]}줄, 화면 맨 위 절은 그대로 "{reloaded["topHeading"]}"')

s0, s1, s2, s3 = (load(f"scroll-memory-{i}.json") for i in range(4))
check("스크롤 위치 기억", s0["topCharacterIndex"] == 0 and s1["topCharacterIndex"] > 0 and s1["topCharacterIndex"] == s2["topCharacterIndex"],
      f'처음 {s0["topCharacterIndex"]} → 저장한 위치 {s1["topCharacterIndex"]}("{s1["topHeading"]}") → 다시 열었을 때 {s2["topCharacterIndex"]}("{s2["topHeading"]}")')
check("스크롤 위치는 문서별", s3["topCharacterIndex"] == 0, f'다른 문서의 위치 {s3["topCharacterIndex"]}')

base, menu = load("03-images-typesetting-light.json"), load("menu.json")
check("메뉴: 글자 크기", menu["fontScale"] == 1.125 and menu["bodySize"] == 18,
      f'배율 {menu["fontScale"]}, 본문 {base["bodySize"]}pt → {menu["bodySize"]}pt')
check("메뉴: 본문 폭", menu["measureScale"] == 1.125 and abs(menu["measure"] - base["measure"] * 1.125 * 1.125) <= 1,
      f'배율 {menu["measureScale"]}, 본문 폭 {base["measure"]}pt → {menu["measure"]}pt (글자 크기 배율 포함)')
check("메뉴: 사이드바 가리기", menu["sidebarCollapsed"] and menu["viewWidth"] > base["viewWidth"],
      f'본문 영역 폭 {base["viewWidth"]}pt → {menu["viewWidth"]}pt')
check("메뉴 동작 뒤에도 문서 맨 위 유지", menu["scrollOffset"] == 0, f'스크롤 위치 {menu["scrollOffset"]}pt')

jump = load("outline-jump.json")
check("목차 이동", jump["outlineRowTitle"] != "" and jump["topHeading"] == jump["outlineRowTitle"],
      f'목차 22번째 줄 "{jump["outlineRowTitle"]}" → 화면 맨 위 절 "{jump["topHeading"]}" (목차 {jump["outlineCount"]}줄)')

print("전체 결과:", "통과" if ok else "실패 있음")
sys.exit(0 if ok else 1)
PY
exit ${pipestatus[1]}
