# mdr

읽기 전용 마크다운 리더입니다. QuickMD만큼 빠르면서 한글과 영문이 모두 잘 읽히는 것을 목표로 합니다.

지금은 2단계까지 됐습니다. macOS 앱이 로컬 파일을 열고, `mdr` 명령으로 원격 호스트(Tailscale로 연결된 기기)의 문서도 엽니다. 3단계는 iOS 앱입니다. 설계 전체와 확정된 결정은 `docs/handoff.md`, 작업 중 알게 된 것과 남은 일은 `docs/progress.md`에 있습니다.

## 필요한 것

- Xcode 26 (Swift 6.2), macOS 14 이상
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- `mdr` 명령을 빌드할 때만: Go 1.27 (`mise use go@1.27.4`). 원격 호스트에는 Go가 필요 없습니다. 빌드한 바이너리 하나만 복사합니다.
- 원격 문서를 열 때만: 문서가 있는 기기와 문서를 보는 Mac이 같은 Tailscale 계정으로 연결돼 있어야 합니다.

## 빌드

```sh
scripts/build.sh            # Debug 빌드 → build/Build/Products/Debug/mdr.app
scripts/build.sh Release    # Release 빌드 → build/Build/Products/Release/mdr.app
```

`scripts/build.sh`는 `project.yml`로 Xcode 프로젝트를 만들고(`mdr.xcodeproj`는 저장소에 넣지 않습니다) `xcodebuild`로 빌드합니다. Xcode에서 열려면 `xcodegen generate` 뒤에 `open mdr.xcodeproj`를 실행하십시오.

공유 Package만 다룰 때는 Xcode 프로젝트가 필요 없습니다.

```sh
swift build     # MdrKit 빌드
swift test      # 단위 테스트

# MdrKit이 iOS에서도 빌드되는지 확인 (AppKit 전용 코드가 섞이지 않았는지)
swift build --build-path .build/ios --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --triple arm64-apple-ios17.0-simulator
```

## 실행

```sh
open -a "$PWD/build/Build/Products/Debug/mdr.app" fixtures/01-korean-handoff.md
```

터미널에서는 아래의 `mdr` 명령을 쓰는 편이 편합니다.

문서 없이 켜면 열기 창이 뜹니다. 파일이 바뀌면 읽던 자리를 지키며 다시 그립니다. 복사하면 일반 글자로 들어가며, 코드 블록은 코드 원문으로, 표는 탭으로 칸을 나눠 넣습니다.

| 메뉴 | 단축키 |
|---|---|
| 보기 > 사이드바 보기/가리기 | ⌃⌘S |
| 보기 > 글자 크게 / 작게 / 기본 크기 | ⌘+ / ⌘- / ⌘0 |
| 보기 > 본문 폭 넓게 / 좁게 / 기본값 | ⌥⌘] / ⌥⌘[ / ⌥⌘0 |
| 보기 > 모양 (시스템 설정 따르기, 라이트, 다크) | |
| 보기 > 스타일 토큰 파일 열기 | ⌥⌘, |
| 편집 > 찾기 | ⌘F |
| 스페이스 / ⇧스페이스 | 한 화면 아래 / 위 |

글자 크기, 본문 폭, 모양은 앱 설정으로 기억합니다. 읽던 자리는 문서마다 기억합니다(로컬 문서는 파일 경로, 원격 문서는 기기와 문서 경로로 가립니다).

## `mdr` 명령: 어느 팬에서든 문서 열기

`mdr 문서.md` 하나로 Mac의 mdr 앱에 문서가 뜹니다. 렌더링은 늘 Mac의 앱이 하고, 문서가 있는 기기는 파일만 내줍니다.

- **문서가 있는 Mac 앞에 앉아 있으면** 앱을 바로 엽니다.
- **그렇지 않으면**(Linux 호스트, SSH 세션, 다른 Mac의 Rex 앱으로 보고 있는 팬) 그 기기에 작은 서버를 띄우고, 누를 수 있는 링크를 출력합니다. 화면에는 파일 이름만 보이고, 누르면 지금 쓰는 Mac의 앱이 문서를 가져와 엽니다.

### 빌드와 설치

```sh
scripts/build-cli.sh          # build/cli/mdr-<os>-<arch> 네 개(macOS arm64·amd64, Linux amd64·arm64). 모두 정적 바이너리입니다
scripts/build-cli.sh test     # Go 테스트를 먼저 돌리고 빌드합니다
```

쓰려는 기기마다 그 기기에 맞는 바이너리를 `mdr`라는 이름으로 PATH에 둡니다.

```sh
# 이 Mac
cp build/cli/mdr-darwin-arm64 ~/.local/bin/mdr          # PATH에 있는 아무 폴더

# 원격 호스트(예: Linux amd64)
scp build/cli/mdr-linux-amd64 호스트:~/.local/bin/mdr
```

원격 호스트에는 Tailscale만 있으면 됩니다. 문서를 볼 Mac에는 mdr 앱이 있어야 하고, 한 번 실행해 두어야 시스템이 `mdr://` 링크를 이 앱에 넘깁니다.

### 쓰는 법

```sh
mdr notes.md                 # 열기. 여러 파일을 한꺼번에 줄 수도 있습니다
mdr --why notes.md           # 바로 열지 링크를 낼지 어떻게 정했는지도 알려 줍니다
mdr --link notes.md          # 항상 링크를 출력합니다
mdr --open notes.md          # 항상 이 Mac의 앱으로 바로 엽니다
mdr --root ~/docs ~/docs/guide/a.md   # 문서 폴더를 넓힙니다(아래 "서버가 내주는 범위")
mdr status                   # 떠 있는 서버의 상태
mdr stop                     # 서버를 끝냅니다. 이전에 출력한 링크는 더 열리지 않습니다
```

서버를 따로 켜고 끄지 않습니다. `mdr 문서.md`가 필요할 때 띄우고, 12시간 동안 아무도 쓰지 않으면 스스로 끝납니다(창을 열어 둔 동안에는 쓰는 것으로 봅니다). 기기를 재시작했거나 서버가 죽었으면 다음 `mdr` 실행이 새로 띄웁니다. 이때 **이전에 출력한 링크는 만료**되고, 앱은 "링크가 만료되었습니다"라고 알립니다. `mdr 문서.md`를 다시 실행해 새 링크를 누르면 앱이 읽던 자리를 이어받습니다.

바로 열지 링크를 낼지는 이렇게 정합니다(`cli/mode.go`). macOS가 아니거나 SSH 세션이면 링크입니다. Rex 팬이면 그 세션을 보고 있는 Rex 앱이 이 Mac의 것뿐이면 바로 열고, 다른 기기의 것뿐이면 링크입니다. 양쪽이 다 붙어 있으면 이 Mac의 키보드·마우스를 5분 안에 썼을 때만 바로 엽니다. 판단이 틀리면 `--link`나 `--open`(또는 환경 변수 `MDR_MODE=link`)으로 정해 주십시오.

출력은 터미널이면 OSC 8 하이퍼링크이고, 터미널이 아니면(파이프, 스크립트) 링크 글자 그대로입니다. `--osc8`과 `--url`로 바꿀 수 있습니다.

### 서버가 내주는 범위

링크는 `mdr://<tailnet 주소>:<포트>/<token>/<경로>` 꼴입니다. 서버는 요청마다 다음을 차례로 확인하고, 하나라도 어긋나면 내주지 않습니다.

1. **tailnet 주소**: 서버는 그 기기의 Tailscale 주소 하나에만 bind하고, 접속한 상대의 주소도 Tailscale 범위인지 봅니다.
2. **계정**: Tailscale whois로 상대 기기가 서버를 띄운 사람의 계정인지 확인합니다. 확인하지 못하면 받지 않습니다. 다른 사람이 공유한 기기나 태그가 붙은 기기는 받지 않습니다.
3. **token**: 문서 폴더마다 무작위 token이 하나 있고 서버의 메모리에만 있습니다. 마지막으로 쓰인 뒤 12시간이 지나면 만료됩니다.
4. **경로**: token은 **문서가 있는 폴더**(`--root`를 주면 그 폴더) 아래만 엽니다. 그 밖을 가리키는 경로와 심볼릭 링크는 막습니다. 폴더 안에서도 마크다운(`.md`, `.markdown`, `.mdown`, `.mkd`)과 이미지, 그리고 `mdr`로 직접 연 파일만 내줍니다.

그래서 문서가 `../images/a.png`처럼 윗 폴더의 이미지를 쓰면 그 이미지는 보이지 않습니다. 그럴 때는 `mdr --root <공통 윗 폴더> 문서.md`로 여십시오.

| 환경 변수 | 뜻 |
|---|---|
| `MDR_MODE=link\|open` | `--link`, `--open`과 같습니다 |
| `MDR_TTL=12h` | 링크가 마지막으로 쓰인 뒤 살아 있는 시간이자, 서버가 쓰이지 않을 때 기다리는 시간 |
| `MDR_PORT=6370` | 서버가 먼저 시도하는 포트. 쓰이고 있으면 빈 포트를 고릅니다 |
| `MDR_APP=/경로/mdr.app` | 바로 열 때 쓸 앱(기본값은 번들 식별자 `dev.mdr.app`으로 찾습니다) |
| `MDR_STATE_DIR` | 서버의 제어 소켓과 기록을 두는 폴더. 기본값은 macOS `~/Library/Application Support/mdr/cli`, Linux `~/.local/state/mdr` |

서버의 기록은 상태 폴더의 `serve.log`에 있습니다. 요청마다 한 줄이 남고 token은 적지 않습니다.

### 앱에서 원격 문서

원격 문서도 로컬 문서와 같게 보입니다. 문서 옆의 이미지, 같은 문서 폴더의 다른 마크다운으로 가는 링크, 문서별 읽던 자리(서버가 다시 떠서 링크가 바뀌어도 이어집니다), 문서가 바뀌면 다시 그리기가 됩니다. 창 제목 아래에는 문서를 내준 기기의 이름이 보입니다.

가져오지 못하면 이유를 본문 자리에 알립니다. 보던 중에 연결이 끊기면 문서는 그대로 두고 창 아래에 한 줄로 알린 뒤 다시 붙습니다.

| 안내 | 뜻과 할 일 |
|---|---|
| Tailscale 연결이 필요합니다 | 이 Mac의 Tailscale이 꺼져 있습니다. 켜면 자동으로 다시 시도합니다 |
| 서버에 연결할 수 없습니다 | 원격 기기가 꺼졌거나 서버가 끝났습니다. 원격 기기에서 `mdr 문서.md`를 다시 실행합니다 |
| 링크가 만료되었습니다 | token이 만료됐거나 서버가 다시 시작됐습니다. `mdr 문서.md`를 다시 실행해 새 링크를 누릅니다 |
| 이 기기는 허용되지 않았습니다 | 이 Mac과 원격 기기의 Tailscale 계정이 다릅니다 |
| 문서를 찾을 수 없습니다 | 원격 기기에서 파일이 지워졌거나 이름이 바뀌었습니다 |

원격 문서의 내용은 믿을 수 없는 입력으로 다룹니다. `mdr://` 링크는 Tailscale 주소(100.x.y.z)의 서버를 가리킬 때만 받습니다. 원격 문서 안에서는 웹·메일 링크와 같은 문서 폴더의 마크다운 링크만 열리고, 이 Mac의 파일을 가리키는 링크와 이미지는 열리지도 읽히지도 않습니다. 웹 이미지도 받지 않습니다.

## 스타일 토큰 편집

조판은 모두 토큰 파일(JSON) 하나가 정합니다. 앱이 켜진 채로 파일을 저장하면 바로 다시 그립니다. 파일에 오류가 있으면 창 아래에 빨간 띠로 알리고 직전의 값을 그대로 씁니다.

앱은 다음 순서로 토큰 파일을 찾아 그 파일을 감시합니다.

1. 환경 변수 `MDR_TOKENS`가 가리키는 파일
2. Debug 빌드: 이 저장소의 `Sources/MdrKit/Resources/tokens.json`
3. `~/Library/Application Support/mdr/tokens.json` (있을 때)
4. 앱에 들어 있는 기본값

그래서 개발 중에는 Debug 빌드를 띄워 놓고 `Sources/MdrKit/Resources/tokens.json`을 고치면 됩니다. Release 빌드에서는 "보기 > 스타일 토큰 파일 열기"를 누르면 기본값을 3번 위치로 복사해 엽니다. 파일에는 바꾸고 싶은 키만 적어도 됩니다. 없는 키는 기본값을 씁니다.

단위는 다음과 같습니다.

- `size`, `step`: 본문 글자 크기에 대한 비율, 또는 modular scale의 단계(크기 = `baseSize` × `scale`^`step`)
- `lineHeight`: 그 요소 글자 크기의 배수
- `spacing`, `spaceBefore`, `spaceAfter`, `indent`, `measure`: 본문 글자 크기(em)의 배수
- `padding*`, `cornerRadius`, `*Width`, `thickness`, `pageMargin`, `pagePaddingY`: pt
- 색: `#RRGGBB` 또는 `#RRGGBBAA`

자주 고칠 키입니다.

| 키 | 뜻 |
|---|---|
| `fonts.body`, `fonts.heading`, `fonts.mono` | `family`는 글꼴 가족 이름 또는 `system`, `system-serif`, `system-rounded`, `system-mono`. `fallbacks`는 `family`에 없는 글자를 찾을 글꼴 순서(한글·라틴 짝) |
| `baseSize`, `scale` | 본문 글자 크기(pt)와 제목 크기의 배율 |
| `measure` | 본문 한 줄의 폭(em). `hangul`과 `latin`을 따로 둘 수 있고, 숫자 하나만 쓰면 둘에 같이 적용 |
| `body.lineHeight` | 본문 행간. `measure`처럼 `hangul`/`latin`을 따로 둘 수 있음 |
| `body.paragraphSpacing` | 문단 사이 간격 |
| `body.lineBreak` | `hangulWord`(어절 단위 줄바꿈), `standard`, `none` |
| `headings[0..5]` | 제목 1~6단계의 `step`, `weight`, `lineHeight`, `spaceBefore`, `spaceAfter`, `tracking`, `color` |
| `colors.light`, `colors.dark` | 테마별 색 |

문서가 한글 문서인지 영문 문서인지는 앞부분 글자에서 한글 음절의 비율로 정합니다(15% 이상이면 한글). `measure`와 `body.lineHeight`의 `hangul`/`latin` 값이 여기에 따라 쓰입니다.

글꼴 짝을 바꾸는 예입니다. 라틴은 시스템 글꼴(SF Pro), 한글은 Pretendard로 씁니다.

```json
{
  "fonts": {
    "body": { "family": "system", "fallbacks": ["Pretendard Variable"] }
  }
}
```

## 검증

```sh
scripts/verify.sh          # 1단계: 조판과 앱 동작을 스냅숏과 측정값으로 확인 → output/verify/ (판정 요약은 SUMMARY.txt)
scripts/verify-remote.sh   # 2단계: 실제 서버와 앱으로 원격 문서를 확인 → output/verify-remote/ (판정 요약은 SUMMARY.txt)
scripts/verify-linux.sh    # 2단계: Linux용 바이너리를 Docker 컨테이너에서 실행 → output/verify-remote/linux-<arch>.txt
scripts/build-cli.sh test  # Go 테스트(서버의 보안 경계 4개, 서버의 수명)
scripts/compare.sh         # 문서마다 mdr와 QuickMD 화면을 나란히 저장 → output/compare/
```

`scripts/verify-remote.sh`는 이 Mac의 Tailscale이 켜져 있어야 합니다. 서버를 이 Mac의 tailnet 주소에 띄우고 앱이 그 링크로 문서를 엽니다. 서버의 상태 폴더를 `/tmp`에 따로 두므로 쓰고 있는 서버가 있어도 건드리지 않고, 떠 있는 mdr 앱도 그대로 둡니다. 먼저 `scripts/build.sh`와 `scripts/build-cli.sh`를 실행해 두어야 합니다.

`scripts/verify-linux.sh`의 컨테이너에는 Tailscale이 없습니다. 그래서 Tailscale이 없을 때 서버가 뜨지 않고 이유를 알리는지와, 테스트 모드(환경 변수 `MDR_INSECURE_DEV_BIND=127.0.0.1`: 그 주소에 bind하고 상대를 확인하지 않음)에서 CLI와 서버가 Linux에서 동작하는지만 봅니다. 이 환경 변수는 테스트에만 씁니다.

`scripts/verify.sh`는 이전 결과를 지우고 시작하며, 스냅숏 실행이 하나라도 실패하거나 판정이 하나라도 어긋나면 0이 아닌 값으로 끝납니다. 먼저 `scripts/build.sh`로 Debug 빌드를 만들어 두어야 합니다.

`scripts/compare.sh`는 QuickMD가 연 창과 같은 크기로, QuickMD처럼 사이드바를 접은 mdr를 찍어 나란히 붙입니다. QuickMD 창을 찍으려면, 스크립트를 실행하는 터미널 앱에 화면 기록 권한이 있어야 합니다(시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 기록). mdr는 자기 창을 스스로 찍으므로 권한이 필요 없습니다.

문서 여는 속도는 앱 바깥에서 잽니다. 어떤 앱이든 같은 방법으로 잴 수 있습니다.

```sh
swiftc -O scripts/bench.swift -o tmp/bench
tmp/bench "$PWD/build/Build/Products/Release/mdr.app" cold 5 큰문서.md
tmp/bench /Applications/QuickMD.app cold 5 큰문서.md
```

측정값의 뜻은 `scripts/bench.swift` 머리말에, 2026-11-13에 잰 값은 `output/bench/`에 있습니다.

스냅숏 한 장만 찍을 때는 `scripts/snap.sh`를 씁니다. 옵션은 `App/macOS/Automation.swift` 머리말에 있습니다. 원격 문서는 파일 대신 `-url "mdr://..."`를 줍니다.

```sh
scripts/snap.sh fixtures/03-images-typesetting.md tmp/a.png -size 1000x690 -appearance dark -scrollTo "V-B"
```

## 구조

```
Package.swift            공유 Package(MdrKit). macOS와 iOS에서 같이 씁니다
Sources/MdrKit/
  Model/                 블록 모델 (플랫폼 타입에 의존하지 않음)
  Parse/                 마크다운 원문 → 블록 모델 (swift-markdown)
  Style/                 토큰, 글꼴, 스타일 해석기
  Render/                블록 모델 → attributed string, 표·코드 블록·이미지 첨부, 장식 그리기
  Source/                문서의 출처: 로컬 파일과 원격 서버(DocumentFeed), mdr:// 링크, 링크 규칙, 원격 이미지
  Resources/             기본 토큰(tokens.json), 번들 글꼴
Tests/MdrKitTests/       단위 테스트
App/macOS/               macOS 앱 (창, 본문 view, 목차, 토큰 감시, 스냅숏 자동화)
cli/                     mdr 명령과 서버 (Go)
  main.go, mode.go         명령 본체, 바로 열지 링크를 낼지 정하기
  internal/server/         앱에게 파일을 내주는 HTTP 서버. 프로토콜은 server.go 머리말에 있습니다
  internal/daemon/         서버의 수명(필요할 때 띄우기, 쓰이지 않으면 끝내기)과 제어 소켓
  internal/tailnet/        Tailscale에게 이 기기의 주소와 상대의 계정을 묻기
project.yml              XcodeGen 프로젝트 정의
fixtures/                비교 기준 문서. remote/는 원격 문서 확인용
scripts/                 빌드, 스냅숏, 검증, 비교, 속도 측정
output/                  검증·비교·측정 결과
docs/                    설계(handoff.md)와 진행 기록(progress.md)
```

## 지원하는 문법

CommonMark와 GFM의 표, 취소선(`~~`만), 체크 목록을 지원합니다. 그 밖에 다음을 다룹니다.

- YAML front matter: 본문에 그리지 않고, `title`은 문서에 1단계 제목이 없을 때 제목으로, `source`는 출처 링크로 보여 줍니다.
- 각주: `[^1]` 참조와 `[^1]: ...` 정의
- 인라인 HTML: `<sup>`, `<sub>`, `<br>`만 의미를 살리고 나머지 태그는 떼어 냅니다.
- 이미지: `![alt](상대경로)`. Obsidian의 `![[name]]`, 웹 주소의 이미지, SVG는 지원하지 않습니다.
- 수식과 Mermaid는 지원하지 않습니다.

## 글꼴

[Pretendard](https://github.com/orioncactus/pretendard) Variable 1.3.9를 앱에 넣었습니다. SIL Open Font License 1.1이며, 라이선스 전문은 `Sources/MdrKit/Resources/Fonts/Pretendard-LICENSE.txt`에 있습니다.
