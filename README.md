# mdr

읽기 전용 마크다운 리더입니다. QuickMD만큼 빠르면서 한글과 영문이 모두 잘 읽히는 것을 목표로 합니다.

지금은 1단계(macOS 앱, 로컬 파일만)입니다. 설계 전체와 확정된 결정은 `docs/handoff.md`, 작업 중 알게 된 것과 남은 일은 `docs/progress.md`에 있습니다.

## 필요한 것

- Xcode 26 (Swift 6.2), macOS 14 이상
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

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

글자 크기, 본문 폭, 모양은 앱 설정으로 기억합니다. 읽던 자리는 문서(파일 경로)마다 기억합니다.

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
scripts/verify.sh     # 완료 조건을 스냅숏과 측정값으로 확인 → output/verify/ (판정 요약은 SUMMARY.txt)
scripts/compare.sh    # 문서마다 mdr와 QuickMD 화면을 나란히 저장 → output/compare/
```

`scripts/verify.sh`는 이전 결과를 지우고 시작하며, 스냅숏 실행이 하나라도 실패하거나 판정이 하나라도 어긋나면 0이 아닌 값으로 끝납니다. 먼저 `scripts/build.sh`로 Debug 빌드를 만들어 두어야 합니다.

`scripts/compare.sh`는 QuickMD가 연 창과 같은 크기로, QuickMD처럼 사이드바를 접은 mdr를 찍어 나란히 붙입니다. QuickMD 창을 찍으려면, 스크립트를 실행하는 터미널 앱에 화면 기록 권한이 있어야 합니다(시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 기록). mdr는 자기 창을 스스로 찍으므로 권한이 필요 없습니다.

문서 여는 속도는 앱 바깥에서 잽니다. 어떤 앱이든 같은 방법으로 잴 수 있습니다.

```sh
swiftc -O scripts/bench.swift -o tmp/bench
tmp/bench "$PWD/build/Build/Products/Release/mdr.app" cold 5 큰문서.md
tmp/bench /Applications/QuickMD.app cold 5 큰문서.md
```

측정값의 뜻은 `scripts/bench.swift` 머리말에, 2026-11-13에 잰 값은 `output/bench/`에 있습니다.

스냅숏 한 장만 찍을 때는 `scripts/snap.sh`를 씁니다. 옵션은 `App/macOS/Automation.swift` 머리말에 있습니다.

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
  Resources/             기본 토큰(tokens.json), 번들 글꼴
Tests/MdrKitTests/       단위 테스트
App/macOS/               macOS 앱 (창, 본문 view, 목차, 토큰 감시, 스냅숏 자동화)
project.yml              XcodeGen 프로젝트 정의
fixtures/                비교 기준 문서
scripts/                 빌드, 스냅숏, 검증, 비교, 속도 측정
output/                  검증·비교·측정 결과
docs/                    설계(handoff.md)와 진행 기록(progress.md)
```

## 지원하는 문법

CommonMark와 GFM의 표, 취소선(`~~`만), 체크 목록을 지원합니다. 그 밖에 다음을 다룹니다.

- YAML front matter: 본문에 그리지 않고, `title`은 문서에 1단계 제목이 없을 때 제목으로, `source`는 출처 링크로 보여 줍니다.
- 각주: `[^1]` 참조와 `[^1]: ...` 정의
- 인라인 HTML: `<sup>`, `<sub>`, `<br>`만 의미를 살리고 나머지 태그는 떼어 냅니다.
- 이미지: `![alt](상대경로)`. Obsidian의 `![[name]]`, 원격 이미지, SVG는 지원하지 않습니다.
- 수식과 Mermaid는 지원하지 않습니다.

## 글꼴

[Pretendard](https://github.com/orioncactus/pretendard) Variable 1.3.9를 앱에 넣었습니다. SIL Open Font License 1.1이며, 라이선스 전문은 `Sources/MdrKit/Resources/Fonts/Pretendard-LICENSE.txt`에 있습니다.
