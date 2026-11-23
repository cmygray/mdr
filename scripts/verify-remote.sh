#!/bin/zsh
# 2단계(원격 문서)를 실제 서버와 앱으로 확인합니다. 결과는 output/verify-remote/에 남습니다.
#
#   scripts/build.sh && scripts/build-cli.sh && scripts/verify-remote.sh
#
# 이 Mac의 Tailscale이 켜져 있어야 합니다. 서버를 이 Mac의 tailnet 주소에 띄우고, 앱이 그 링크로 문서를 엽니다.
# 서버의 상태 폴더는 /tmp에 따로 두므로, 원이 쓰고 있는 서버(있다면)는 건드리지 않습니다.
# 이전 결과를 지우고 시작하고, 판정이 하나라도 어긋나면 0이 아닌 값으로 끝납니다.
#
# 결과 파일에는 이 기기의 tailnet 주소, 기기 이름, 확인에 쓴 링크의 token이 들어갑니다. 그래서 저장소에는
# 요약(SUMMARY.txt)만 넣고 나머지는 .gitignore로 뺍니다. 요약도 끝날 때 실제 값을 예시 값으로 바꿉니다
# (scripts/check-private.py --redact). 스냅숏에는 창 제목 아래에 기기 이름이 찍혀 있어 가릴 수 없습니다.
set -uo pipefail
cd "$(dirname "$0")/.."
out="$PWD/output/verify-remote"
mkdir -p "$out" tmp
find "$out" -type f -delete
log="$out/run.log"

arch=$(uname -m); [ "$arch" = x86_64 ] && arch=amd64
mdr="$PWD/build/cli/mdr-darwin-$arch"
app="$PWD/build/Build/Products/Debug/mdr.app"
bin="$app/Contents/MacOS/mdr"
[ -x "$mdr" ] || { echo "먼저 scripts/build-cli.sh를 실행하십시오"; exit 1; }
[ -x "$bin" ] || { echo "먼저 scripts/build.sh를 실행하십시오"; exit 1; }
[ -x tmp/shot ] && [ tmp/shot -nt scripts/shot.swift ] || swiftc -O scripts/shot.swift -o tmp/shot || exit 1

export MDR_STATE_DIR=/tmp/mdr-verify-remote
export MDR_MODE=link
export MDR_PORT=6399
"$mdr" stop >/dev/null 2>&1
rm -rf "$MDR_STATE_DIR"

# 문서는 저장소 밖의 사본으로 확인합니다(실행 중에 고치기 때문입니다).
work="$PWD/tmp/verify-remote"
rm -rf "$work"; mkdir -p "$work"
cp -R fixtures/remote "$work/docs"
print -r -- "TOP-SECRET-OUTSIDE-ROOT" > "$work/secret.md"
ln -s ../secret.md "$work/docs/link-out.md"
doc="$work/docs/index.md"

# 앱을 자동화 모드로 띄워 스냅숏과 측정값을 남깁니다. 25초 안에 끝나지 않으면 강제로 끝냅니다.
snap() {
  local name="$1"; shift
  "$bin" -snapshot "$out/$name.png" -metrics "$out/$name.json" -size 1000x690 -exit YES \
    -ApplePersistenceIgnoreState YES "$@" >> "$log" 2>&1 &
  local pid=$!
  ( sleep 25; kill -9 $pid 2>/dev/null ) &
  local killer=$!
  wait $pid 2>/dev/null
  kill $killer 2>/dev/null
}
status() { "$mdr" status 2>/dev/null; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }
code() { curl -s -m 5 -o "$out/body.tmp" -w '%{http_code}' "$@"; }

echo "== 1. 명령 하나로 서버가 뜨고 링크가 나오는지"
link=$("$mdr" --url "$doc" 2>>"$log")
print -r -- "$link" > "$out/link.txt"
status > "$out/status.json"
pid=$(status | field pid); addr=$(status | field addr); port=${addr##*:}; host=${addr%:*}
token=${${link#mdr://*/}%%/*}
lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' > "$out/listen.txt"
"$mdr" --osc8 "$doc" 2>>"$log" | od -c | head -12 > "$out/osc8.txt"
"$mdr" --osc8 "$doc" 2>>"$log" > "$out/osc8.raw"

echo "== 2. 서버의 보안 경계(실제 네트워크)"
base="http://$addr/v1/$token"
lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
{
  echo "valid=$(code $base/files/index.md)"
  echo "image=$(code $base/files/img/flow.png)"
  echo "loopback=$(code http://127.0.0.1:$port/v1/$token/files/index.md)"
  echo "lan=$(code http://${lan:-192.0.2.1}:$port/v1/$token/files/index.md)"
  echo "wrong_token=$(code http://$addr/v1/not-the-token/files/index.md)"
  echo "dotdot=$(code --path-as-is "$base/files/../secret.md")"; cat "$out/body.tmp" >> "$out/leak-check.txt"
  echo "encoded=$(code "$base/files/%2e%2e/secret.md")"; cat "$out/body.tmp" >> "$out/leak-check.txt"
  echo "encoded_slash=$(code "$base/files/..%2Fsecret.md")"; cat "$out/body.tmp" >> "$out/leak-check.txt"
  echo "symlink=$(code "$base/files/link-out.md")"; cat "$out/body.tmp" >> "$out/leak-check.txt"
  echo "other_type=$(code "$base/files/data.csv")"
  echo "lan_ip=${lan:-없음}"
} > "$out/boundary.txt"
rm -f "$out/body.tmp"

echo "== 3. 앱이 원격 문서를 여는지(이미지, 믿을 수 없는 참조)"
: > "$MDR_STATE_DIR/serve.log"
snap open -url "$link" -wait 1.5
cp "$MDR_STATE_DIR/serve.log" "$out/open-requests.log"
snap untrusted -url "$link" -scrollTo "그려지지" -wait 1.5
# 같은 문서를 원격과 로컬로 열어 조판이 같은지 봅니다(1단계 fixture, 이미지 3장).
cp -R fixtures/images fixtures/03-images-typesetting.md "$work/"
link_same=$("$mdr" --url "$work/03-images-typesetting.md" 2>>"$log")
snap same-remote -url "$link_same" -scrollTo "3-A" -wait 1.5
scripts/snap.sh "$work/03-images-typesetting.md" "$out/same-local.png" -size 1000x690 -scrollTo "3-A" -metrics "$out/same-local.json" >> "$log" 2>&1

echo "== 4. 문서가 바뀌면 읽던 자리를 지키며 다시 그리는지(SSE)"
( sleep 2; print -r -- $'\n\n## 실행 중에 붙인 절\n\n서버가 변경을 알려 주어 다시 그린 문단입니다.' >> "$doc" ) &
snap reload -url "$link" -scrollTo "긴 본문" -wait 4
wait

echo "== 5. 문서 안의 링크: 같은 문서 폴더의 문서는 열리고, 나머지는 열리지 않는지"
snap link-second -url "$link" -followLink "둘째 문서" -wait 1.5
pgrep -x Calculator > /dev/null && calculator_before=yes || calculator_before=no
snap link-outside -url "$link" -followLink "폴더 밖 문서" -wait 0.5
snap link-localfile -url "$link" -followLink "계산기" -wait 0.5
snap link-otherserver -url "$link" -followLink "다른 서버" -wait 0.5
snap link-nonmarkdown -url "$link" -followLink "데이터" -wait 0.5
pgrep -x Calculator > /dev/null && calculator_after=yes || calculator_after=no
print -r -- "$calculator_before $calculator_after" > "$out/calculator.txt"

echo "== 6. 읽던 자리: 서버가 다시 떠서 링크가 바뀌어도 이어지는지"
snap position-0-reset -url "$link" -persist YES -scrollFraction 0 -wait 1
snap position-1-saved -url "$link" -persist YES -scrollTo "끝" -wait 1
"$mdr" stop >> "$log" 2>&1
link2=$("$mdr" --url "$doc" 2>>"$log")
print -r -- "$link2" > "$out/link-after-restart.txt"
snap position-2-restored -url "$link2" -persist YES -wait 1

echo "== 6-2. 보던 중에 서버가 다시 떠서 새 링크를 받은 경우: 죽은 링크의 창을 닫고 새 창이 자리를 이어받는지"
later="$work/later.txt"; : > "$later"
( sleep 1.5; "$mdr" stop >> "$log" 2>&1; "$mdr" --url "$doc" > "$later" 2>>"$log" ) &
snap relink -url "$link2" -persist YES -openLater "$later" -openLaterAfter 4 -wait 1
wait
link2=$(cat "$later")
print -r -- "$link2" > "$out/link-relinked.txt"

echo "== 7. 가져오지 못할 때의 안내"
token2=${${link2#mdr://*/}%%/*}
# Tailscale이 꺼져 있다가(처음 2.5초) 켜지면 다시 시도해 문서를 엽니다.
# (안내 화면이 뜬 뒤 4초를 기다리게 해서, 그 사이에 문서가 도착하는지 봅니다.)
snap recover -url "$link2" -assumeTailscale off:2.5 -wait 4
snap error-expired -url "${link2/$token2/expired-token-000}" -wait 1
: > "$MDR_STATE_DIR/serve.log"
snap error-tailscale-off -url "$link2" -assumeTailscale off -wait 1
cp "$MDR_STATE_DIR/serve.log" "$out/tailscale-off-requests.log"
snap error-missing -url "${link2%/*}/no-such-file.md" -wait 1
"$bin" -url "mdr://127.0.0.1:$port/$token2/index.md" -metrics "$out/reject-loopback.json" -exit YES -ApplePersistenceIgnoreState YES >> "$log" 2>&1
"$bin" -url "mdr://example.com:80/$token2/index.md" -metrics "$out/reject-hostname.json" -exit YES -ApplePersistenceIgnoreState YES >> "$log" 2>&1
# 문서를 보는 중에 서버가 끝나면 창 아래에 알립니다.
( sleep 2; "$mdr" stop >> "$log" 2>&1 ) &
snap stale -url "$link2" -wait 4.5
wait
# 서버가 없을 때
snap error-unreachable -url "$link2" -wait 1

echo "== 8. 시스템이 mdr:// 링크를 앱에 넘기는지(open 명령)"
# 이미 떠 있는 mdr 앱(원이 쓰는 창)은 건드리지 않습니다. 새 인스턴스를 따로 띄우고 그것만 끝냅니다.
link3=$("$mdr" --url "$doc" 2>>"$log")
handler=$(tmp/shot handler "$link3" 2>/dev/null)
before=$(pgrep -x mdr | sort | tr '\n' ' ')
open -n -g -a "$app" "$link3" --args -ApplePersistenceIgnoreState YES
streams=0
for i in $(seq 1 40); do
  streams=$(status | field streams)
  [ "$streams" = 1 ] && break
  sleep 0.25
done
sleep 0.5
started=""
for candidate in $(pgrep -x mdr); do
  # 이 확인이 띄운 것만 고릅니다: 확인 전에는 없었고, 이 저장소에서 빌드한 앱의 실행 파일인 프로세스
  [[ " $before " == *" $candidate "* ]] && continue
  [ "$(ps -o comm= -p $candidate 2>/dev/null)" = "$bin" ] && started="$started $candidate"
done
print -r -- "streams=$streams started=${started# } handler=$handler" > "$out/url-scheme.txt"
for candidate in ${=started}; do kill -TERM $candidate 2>/dev/null; done
sleep 1
print -r -- "after=$(pgrep -x mdr | sort | tr '\n' ' ') before=$before" >> "$out/url-scheme.txt"
"$mdr" stop >> "$log" 2>&1
print -r -- "$(status)" > "$out/final-status.txt"

echo "== 요약"
python3 - "$out" <<'PY' | tee "$out/SUMMARY.txt"
import json, os, re, subprocess, sys, datetime
out = sys.argv[1]
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
dirty = subprocess.run(["git", "status", "--porcelain", "--", ".", ":!output"], capture_output=True, text=True).stdout.strip() != ""
print(f"검증 시각 {datetime.datetime.now():%Y-%m-%d %H:%M}, 커밋 {commit}{' + 커밋하지 않은 변경' if dirty else ''}")

def text(name):
    path = os.path.join(out, name)
    return open(path, errors="replace").read() if os.path.exists(path) else ""

def load(name):
    try:
        return json.load(open(os.path.join(out, name)))
    except Exception:
        return {}

def pixel(name, x, y):
    result = subprocess.run(["tmp/shot", "pixel", os.path.join(out, name), str(x), str(y)], capture_output=True, text=True)
    return [float(value) for value in result.stdout.split()]

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and bool(condition)
    print(("  통과  " if condition else "  실패  ") + label + " — " + detail)

print("서버")
link = text("link.txt").strip()
status = load("status.json")
listen = text("listen.txt").split()
check("명령 하나로 서버가 뜨고 링크가 나옴", re.fullmatch(r"mdr://100\.\d+\.\d+\.\d+:\d+/[\w-]{20,}/index\.md", link) and status.get("pid"),
      f'{re.sub(r"/[^/]+/index", "/<token>/index", link)} (서버 pid {status.get("pid")}, 버전 {status.get("version")})')
check("tailnet 주소에만 bind", listen and all(re.match(r"100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", a) for a in listen),
      f'서버가 듣는 주소: {", ".join(listen) or "없음"}')
osc = open(os.path.join(out, "osc8.raw"), "rb").read() if os.path.exists(os.path.join(out, "osc8.raw")) else b""
check("OSC 8 하이퍼링크로 출력, 화면에는 파일 이름만", osc == b"\x1b]8;;" + link.encode() + b"\x1b\\index.md\x1b]8;;\x1b\\\n",
      f'ESC ] 8 ; ; <링크> ESC \\ index.md ESC ] 8 ; ; ESC \\ ({len(osc)}바이트)')
b = dict(line.split("=", 1) for line in text("boundary.txt").split() if "=" in line)
check("올바른 요청은 통과", b.get("valid") == "200" and b.get("image") == "200", f'문서 {b.get("valid")}, 이미지 {b.get("image")} (whois로 이 Mac의 계정을 확인한 뒤 통과)')
check("tailnet이 아닌 주소로는 연결 자체가 안 됨", b.get("loopback") == "000" and b.get("lan") == "000",
      f'127.0.0.1 → {b.get("loopback")}, LAN 주소 {b.get("lan_ip")} → {b.get("lan")} (000은 연결 거부)')
check("잘못된 token", b.get("wrong_token") == "401", f'{b.get("wrong_token")}')
leak = "TOP-SECRET" in text("leak-check.txt")
check("경로 탈출", all(b.get(k) == "403" for k in ["dotdot", "encoded", "encoded_slash", "symlink"]) and not leak,
      f'../ → {b.get("dotdot")}, %2e%2e → {b.get("encoded")}, ..%2F → {b.get("encoded_slash")}, 폴더 밖을 가리키는 심볼릭 링크 → {b.get("symlink")}, 폴더 밖 파일 내용 노출 {"있음" if leak else "없음"}')
check("마크다운·이미지가 아닌 파일", b.get("other_type") == "403", f'data.csv → {b.get("other_type")}')

print("앱")
m = load("open.json")
check("원격 문서를 엶", m.get("feedState") == "live" and m.get("textLength", 0) > 0 and m.get("windowTitle") == "index.md"
      and m.get("windowSubtitle") == status.get("host"),
      f'상태 {m.get("feedState")}, 글자 수 {m.get("textLength")}, 창 제목 "{m.get("windowTitle")}", 부제(서버 기기 이름) "{m.get("windowSubtitle")}"')
remote, local = load("same-remote.json"), load("same-local.json")
same = ["textLength", "documentHeight", "scrollOffset", "topHeading", "imageCount", "outlineCount", "bodyLeft", "measure"]
check("같은 문서의 조판이 로컬과 같음(이미지 3장)", remote.get("documentHeight", 0) > 0 and remote.get("imageCount") == 3
      and remote.get("pendingImageAttachments") == 0 and all(remote.get(k) == local.get(k) for k in same),
      f'문서 높이 {remote.get("documentHeight")}pt = 로컬 {local.get("documentHeight")}pt, "{remote.get("topHeading")}"로 이동한 스크롤 위치 {remote.get("scrollOffset")}pt = 로컬 {local.get("scrollOffset")}pt, 이미지 {remote.get("imageCount")}장')
images = m.get("remoteImages", {})
check("이미지를 문서 뒤에 받아 채움", images.get("loaded") == 1 and m.get("pendingImageAttachments") == 0 and m.get("imagePixelWidths") == [360.0],
      f'받은 이미지 {images.get("loaded")}장, 받지 못한 것 {images.get("failed")}장, 자리만 잡힌 채 남은 것 {m.get("pendingImageAttachments")}장, 그려진 이미지의 픽셀 폭 {m.get("imagePixelWidths")}')
requests = re.findall(r'요청 GET (files|events) "([^"]+)" (?:→ (\d+)|시작)', text("open-requests.log"))
asked = sorted({path for _, path, _ in requests})
check("믿을 수 없는 이미지 참조에는 요청을 보내지 않음", asked == ["img/flow.png", "img/missing.png", "index.md"] and m.get("imageCount") == 1,
      f'서버가 받은 요청의 경로: {asked} (폴더 밖·웹·file: 이미지는 요청 없이 대체 글자로 표시, 본문의 이미지 {m.get("imageCount")}장)')

r = load("reload.json")
check("문서 변경을 받아 다시 그림", r.get("outlineCount") == m.get("outlineCount", 0) + 1 and r.get("topHeading") == "긴 본문" and r.get("feedState") == "live",
      f'목차 {m.get("outlineCount")}줄 → {r.get("outlineCount")}줄, 화면 맨 위 절은 그대로 "{r.get("topHeading")}"')

second = load("link-second.json")
check("문서 안의 링크로 같은 폴더의 문서를 엶", second.get("followLinkOpened") is True and second.get("windowTitle") == "second.md"
      and second.get("source", "").endswith("/guide/second.md") and second.get("imagePixelWidths") == [360.0],
      f'새 창 "{second.get("windowTitle")}", 열린 문서 {second.get("documentCount")}개, 그 문서의 이미지(../img/flow.png) 픽셀 폭 {second.get("imagePixelWidths")}')
denied = {name: load(f"link-{name}.json") for name in ["outside", "localfile", "otherserver", "nonmarkdown"]}
calculator = text("calculator.txt").split()
check("막아야 하는 링크는 열리지 않음", all(d.get("followLinkOpened") is False and d.get("documentCount") == 1 for d in denied.values())
      and len(calculator) == 2 and calculator[0] == calculator[1],
      "폴더 밖 문서, 이 Mac의 파일(계산기), 다른 서버, 마크다운이 아닌 파일: 새 문서 "
      + ", ".join("열림" if d.get("followLinkOpened") else "안 열림" for d in denied.values())
      + f'; 계산기 실행 여부 전 {calculator[0] if calculator else "?"} → 후 {calculator[1] if len(calculator) > 1 else "?"}')

p0, p1, p2 = (load(f"position-{name}.json") for name in ["0-reset", "1-saved", "2-restored"])
link2 = text("link-after-restart.txt").strip()
check("서버가 다시 뜨면 링크(token)가 바뀜", link2 and link2 != link, "이전 링크와 다름" if link2 != link else "같음")
check("읽던 자리는 token이 바뀌어도 이어짐", p0.get("topCharacterIndex") == 0 and p1.get("topCharacterIndex", 0) > 0
      and p2.get("topCharacterIndex") == p1.get("topCharacterIndex") and p1.get("positionKey") == p2.get("positionKey") and "/id/" in p1.get("positionKey", ""),
      f'처음 {p0.get("topCharacterIndex")} → 저장 {p1.get("topCharacterIndex")}("{p1.get("topHeading")}") → 새 링크로 열었을 때 {p2.get("topCharacterIndex")}("{p2.get("topHeading")}"), 키 {re.sub(r"/id/[0-9a-f]+", "/id/<문서 이름표>", p1.get("positionKey", ""))}')

relink = load("relink.json")
relinked = text("link-relinked.txt").strip()
check("새 링크로 열면 죽은 링크의 창을 닫고 자리를 이어받음", relink.get("source") == relinked and relinked != link2 and relink.get("documentCount") == 1
      and relink.get("feedState") == "live" and relink.get("topCharacterIndex") == p1.get("topCharacterIndex"),
      f'열린 문서 {relink.get("documentCount")}개(새 링크의 문서), 상태 {relink.get("feedState")}, 읽던 자리 {relink.get("topCharacterIndex")}("{relink.get("topHeading")}")')

menu_actions = m.get("contextMenuActions")
check("오른쪽 단추 메뉴에 링크를 여는 항목이 없음", isinstance(menu_actions, list) and menu_actions and set(menu_actions) <= {"copy:", "copyLink:", "selectAll:", "_lookUpDefiniteRangeInDictionaryFromMenu:", "_lookUpIndefiniteRangeInDictionaryFromMenu:"},
      f'첫 링크 위에서의 메뉴 항목: {menu_actions}')

print("가져오지 못할 때의 안내")
recover = load("recover.json")
check("Tailscale이 켜지면 자동으로 다시 시도해 엶", recover.get("statusHistory") == ["Tailscale 연결이 필요합니다"] and recover.get("feedState") == "live"
      and recover.get("textLength", 0) > 0,
      f'처음 안내 {recover.get("statusHistory")} → 2.5초 뒤 Tailscale이 켜진 것으로 바꾸자 상태 {recover.get("feedState")}, 글자 수 {recover.get("textLength")}')
def status_check(label, name, title):
    e = load(f"{name}.json")
    check(label, e.get("feedState") == "failed" and e.get("statusTitle") == title,
          f'"{e.get("statusTitle")}" — {e.get("statusDetail")}')
status_check("Tailscale이 꺼져 있을 때(꺼진 것으로 가정)", "error-tailscale-off", "Tailscale 연결이 필요합니다")
check("그때 서버로 요청을 보내지 않음", "요청" not in text("tailscale-off-requests.log"), "서버 기록에 요청 없음")
status_check("token이 틀리거나 만료됐을 때", "error-expired", "링크가 만료되었습니다")
status_check("파일이 없을 때", "error-missing", "문서를 찾을 수 없습니다")
status_check("서버가 없을 때", "error-unreachable", "서버에 연결할 수 없습니다")
stale = load("stale.json")
check("보는 중에 서버가 끝났을 때", stale.get("feedState") == "stale" and "서버에 연결할 수 없습니다" in stale.get("notice", "") and stale.get("textLength", 0) > 0,
      f'창 아래 안내 "{stale.get("notice")}", 문서는 그대로 보임(글자 수 {stale.get("textLength")})')
band = pixel("stale.png", 0.97, 0.992)
check("그 안내가 화면에 보임", len(band) == 3 and band[0] > 0.8 and band[2] < 0.5, f'창 아래 띠 픽셀 {band}')
for name, label in [("reject-loopback", "tailnet 주소가 아닌 링크(127.0.0.1)"), ("reject-hostname", "이름으로 된 링크(example.com)")]:
    e = load(f"{name}.json")
    check(f"{label}는 열지 않음", e.get("linkRejected") and e.get("documentCount") == 0, f'{e.get("linkRejected")}')

print("시스템 연결")
scheme = text("url-scheme.txt")
found = dict(re.findall(r"(\w+)=(.*?)(?= \w+=|$)", scheme, flags=re.M))
check("mdr:// 링크를 받는 앱으로 등록됨", found.get("handler", "").endswith("/mdr.app"), f'시스템이 mdr:// 주소를 넘겨줄 앱: {found.get("handler")}')
check("open으로 넘긴 mdr:// 링크를 앱이 열어 문서를 가져감", found.get("streams") == "1" and found.get("started", "").strip().isdigit(),
      f'새로 띄운 앱 pid {found.get("started")}, 서버에 열린 변경 알림 연결 {found.get("streams")}개')
check("확인에 쓴 앱만 끝내고 원래 떠 있던 앱은 그대로 둠", found.get("after", "").split() == found.get("before", "").split(),
      f'확인 전 mdr 프로세스 [{found.get("before", "").strip()}] = 확인 후 [{found.get("after", "").strip()}]')
check("확인 뒤 서버가 남아 있지 않음", "없습니다" in text("final-status.txt"), text("final-status.txt").strip())

print("전체 결과:", "통과" if ok else "실패 있음")
sys.exit(0 if ok else 1)
PY
result=${pipestatus[1]}
# 이 기기의 tailnet 주소·기기 이름·경로를 예시 값으로 바꿉니다. Tailscale에서 값을 읽지 못하면 실패로 봅니다.
scripts/check-private.py --redact "$out" || result=1
exit $result
