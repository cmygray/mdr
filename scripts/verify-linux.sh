#!/bin/zsh
# Linux용 바이너리(amd64, arm64)를 Docker 컨테이너에서 실행해 봅니다. 결과는 output/verify-remote/linux-<arch>.txt에 남습니다.
#
#   scripts/build-cli.sh && scripts/verify-linux.sh
#
# 컨테이너에는 Tailscale이 없습니다. 그래서 (1) Tailscale이 없을 때 서버가 뜨지 않고 이유를 알리는지,
# (2) 테스트 모드(127.0.0.1에 bind, 상대 확인 없음)에서 CLI·서버·수명 관리가 Linux에서 동작하는지만 봅니다.
# tailnet 주소 bind와 whois는 이 스크립트로 확인하지 못합니다.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p output/verify-remote
# 공개 이미지(alpine)만 쓰므로 로그인 정보가 필요 없습니다. Docker Desktop의 자격 증명 도우미는 키체인 창을 띄우며
# 멈출 수 있어서(화면이 잠겨 있을 때), 빈 설정 폴더로 실행해 그것을 건너뜁니다.
config=$(mktemp -d /tmp/mdr-docker-config.XXXXXX)
print -r -- '{}' > "$config/config.json"
export DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)}"
export DOCKER_CONFIG="$config"
trap 'rm -rf "$config"' EXIT
failed=0
for arch in arm64 amd64; do
  result="output/verify-remote/linux-$arch.txt"
  docker run --rm --platform "linux/$arch" -v "$PWD/build/cli/mdr-linux-$arch:/usr/local/bin/mdr:ro" alpine:3.20 sh -c '
    set -u
    ok=1
    check() { if [ "$2" = "$3" ]; then echo "  통과  $1 — $2"; else echo "  실패  $1 — $2 (기대: $3)"; ok=0; fi; }
    has() { case "$2" in *"$3"*) echo "  통과  $1 — $2" ;; *) echo "  실패  $1 — $2 (기대: \"$3\" 포함)"; ok=0 ;; esac; }
    echo "$(uname -s) $(uname -m), $(mdr version)"
    mkdir -p /work/docs/img && cd /work
    printf "# linux\n" > docs/note.md; printf "PNG" > docs/img/a.png; printf "SECRET" > secret.md
    ln -s ../secret.md docs/link-out.md
    fetch() { wget -q -O - "$1" 2>/dev/null; }
    code() { wget -S -q -O /dev/null "$1" 2>&1 | sed -n "s/.*HTTP\\/[0-9.]* \\([0-9][0-9][0-9]\\).*/\\1/p" | tail -1; }

    echo "Tailscale이 없는 호스트"
    out=$(MDR_MODE=link mdr --url docs/note.md 2>&1); rc=$?
    check "mdr FILE이 실패로 끝남" "$rc" "1"
    has "이유를 알림" "$out" "Tailscale"
    has "서버가 남지 않음" "$(mdr status)" "떠 있는 서버가 없습니다"

    echo "테스트 모드(127.0.0.1, 상대 확인 없음)"
    export MDR_INSECURE_DEV_BIND=127.0.0.1 MDR_PORT=6400
    link=$(mdr --url docs/note.md 2>/dev/null)
    has "명령 하나로 서버가 뜨고 링크가 나옴(macOS가 아니면 항상 링크)" "$link" "mdr://127.0.0.1:6400/"
    base="http://127.0.0.1:6400/v1/$(echo "$link" | cut -d/ -f4)"
    check "문서" "$(fetch $base/files/note.md)" "# linux"
    check "이미지" "$(fetch $base/files/img/a.png)" "PNG"
    check "잘못된 token" "$(code http://127.0.0.1:6400/v1/wrong/files/note.md)" "401"
    check "인코딩된 경로 탈출" "$(code $base/files/%2e%2e/secret.md)" "403"
    check "폴더 밖을 가리키는 심볼릭 링크" "$(code $base/files/link-out.md)" "403"
    check "폴더 밖 파일 내용이 나오지 않음" "$(fetch $base/files/link-out.md)" ""
    pid=$(mdr status | sed -n "s/.*\"pid\": \\([0-9]*\\).*/\\1/p")
    has "상태 폴더는 XDG 위치" "$(ls -d ~/.local/state/mdr/ctl.sock 2>&1)" ".local/state/mdr/ctl.sock"
    check "제어 소켓 권한" "$(stat -c %a ~/.local/state/mdr/ctl.sock)" "600"
    check "상태 폴더 권한" "$(stat -c %a ~/.local/state/mdr)" "700"
    check "같은 문서는 같은 링크" "$(mdr --url docs/note.md 2>/dev/null)" "$link"
    # 변경 알림: 연결을 열어 두고 파일을 고칩니다.
    ( wget -q -O /tmp/events.txt "$base/events/note.md" 2>/dev/null & echo $! > /tmp/wget.pid )
    sleep 1; printf "# changed\n" > docs/note.md; sleep 1.5; kill $(cat /tmp/wget.pid) 2>/dev/null
    has "변경 알림(SSE)" "$(tr "\n" " " < /tmp/events.txt)" "event: change"
    # 강제 종료 뒤의 다음 실행
    kill -9 "$pid"; sleep 0.3
    link2=$(mdr --url docs/note.md 2>/dev/null)
    pid2=$(mdr status | sed -n "s/.*\"pid\": \\([0-9]*\\).*/\\1/p")
    check "강제 종료 뒤 다음 실행이 새 서버를 띄움" "$([ -n "$pid2" ] && [ "$pid2" != "$pid" ] && echo yes)" "yes"
    check "새 링크로 문서를 가져옴" "$(fetch http://127.0.0.1:6400/v1/$(echo "$link2" | cut -d/ -f4)/files/note.md)" "# changed"
    check "이전 링크는 만료" "$(code $base/files/note.md)" "401"
    mdr stop >/dev/null
    # 쓰이지 않으면 스스로 끝남
    MDR_TTL=1s mdr --url docs/note.md >/dev/null 2>&1; pid3=$(mdr status | sed -n "s/.*\"pid\": \\([0-9]*\\).*/\\1/p")
    sleep 3
    check "쓰이지 않으면 스스로 끝남" "$(kill -0 "$pid3" 2>/dev/null && echo alive || echo gone)" "gone"
    has "끝난 뒤 상태" "$(mdr status)" "떠 있는 서버가 없습니다"
    [ $ok = 1 ] && echo "결과: 통과" || echo "결과: 실패 있음"
    [ $ok = 1 ]
  ' > "$result" 2>&1 || failed=1
  echo "== linux/$arch"; cat "$result"
done
exit $failed
