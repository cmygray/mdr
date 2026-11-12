# 마크다운 리더(mdr) 이어받기

읽기 전용 마크다운 리더를 설계하고 있습니다. 아래 결정은 이미 확정됐으니 다시 논의하지 말고 이어서 진행해 주십시오. 응답은 한국어 하십시오체로 합니다.

## 목표
- 기준점은 QuickMD입니다. 속도는 만족스럽지만 가독성과 디자인이 아쉽습니다. QuickMD만큼 빠르면서 더 잘 읽히는 리더를 만듭니다.
- macOS와 iOS 둘 다 지원합니다.
- Rex 터미널 팬(로컬, 또는 Tailscale로 연결된 원격 Linux 호스트)에서 명령 하나로 문서를 열 수 있어야 합니다.

## 확정된 결정
1. 읽기 전용입니다. 수식과 Mermaid는 지원하지 않습니다(필요해지면 렌더러를 직접 만듭니다).
2. 터미널 글자로 그리는 방식은 쓰지 않습니다. 가독성이 부족합니다.
3. Rex 팬 안에 그리는 방식(kitty graphics)도 쓰지 않습니다. 이유: Rex가 kitty 이미지를 point 해상도(1x)로 다시 샘플링해서, 레티나에서 2x 이미지가 흐려집니다(1px 패턴으로 확인).
4. 대신 **Rex 팬의 명령이 네이티브 앱을 여는 방식**을 씁니다. 렌더링은 Mac·iPhone에서 합니다. 그래서 원격 호스트는 파일만 내줍니다.
5. 조판 원칙 1~5를 모두 채택합니다.
   1. 스타일은 데이터 토큰(글꼴, 크기 비율, 행간, 간격, 색)으로 렌더러와 분리하고, 개발 중에는 고치면 바로 다시 그려지게 합니다.
   2. 한국어 조판: `lineBreakStrategy = .hangulWordPriority`(어절 단위 줄바꿈), 행간 약 1.6~1.75배, `kCTFontCascadeListAttribute`로 한글·라틴 글꼴 짝을 명시하고, Pretendard(OFL) 번들을 검토합니다.
   3. 본문 폭 제한과 가운데 정렬: 한글 한 줄 35~45자, 영문 60~75자.
   4. 세로 리듬: 제목 크기는 modular scale(1.2~1.25배), 제목 위 여백을 아래보다 크게, 코드 블록은 가로 스크롤.
   5. 목차와 개요 사이드바, 문서별 스크롤 위치 기억, 본문 폭·글꼴 크기 선택, 라이트·다크 테마.

## 구조
| 구성 | 기술 | 역할 |
|---|---|---|
| 리더 앱 (macOS·iOS) | Swift + TextKit 2. 공유 Swift Package(파서 → 블록 모델 → 스타일 해석기) 위에 얇은 플랫폼 view. 표·코드 블록은 `NSTextAttachmentViewProvider`(iOS에 `NSTextTable`이 없으므로). 파서는 `swift-markdown`(cmark-gfm)으로 시작 | 렌더링 전부 |
| `mdr` CLI | 정적 바이너리 하나 | 같은 Mac이면 `open`으로 앱을 바로 엽니다. 원격이면 서버를 띄우고 OSC 8 링크를 출력합니다 |
| `mdr serve` | tailnet IP에만 bind, 링크마다 token, 문서 폴더 밖 경로 차단, 가능하면 Tailscale whois로 내 계정만 허용, 파일 변경은 SSE로 알림 | 마크다운 원문과 상대 경로 이미지를 내줌. 앱이 가져가는(pull) 방식입니다. iOS 앱은 백그라운드에서 연결을 기다릴 수 없어서 보내는(push) 방식은 쓸 수 없습니다 |

링크 형식: `mdr://<host>:<port>/<token>/<path>`. 화면에는 파일 이름만 보이게 합니다.

## Rex에서 확인한 사실 (2026-11-12~13 실험)
- OSC 8 링크: https는 기본 브라우저로, custom scheme(`shortcuts://`)은 해당 앱으로 열립니다. 화면 글자와 URL이 달라도 열립니다. Mac과 iOS Rex 둘 다 됩니다.
- 처리할 앱이 없는 scheme: Mac은 "링크를 열 수 없음" 오류 창, iOS는 무반응입니다. 그래서 https 대체 링크를 함께 출력하는 것을 검토합니다(우선순위 낮음).
- OSC 8 없는 평문 URL은 클릭할 수 없습니다. 그래서 CLI는 항상 OSC 8로 출력합니다.
- `rex split`으로 CLI에서 만든 팬은 owner가 null이라 크기가 서버 기본값(80×24, 셀 8×16)으로 남습니다. 실제 Mac 셀은 7×15입니다. 팬에서 실험할 때는 `rex block call -b <id> resize '{...}'`로 크기를 맞춰야 합니다.
- QuickMD 번들 분석: 본문은 `NSTextView` + attributed string, 수식은 OpenType Math 폰트로 네이티브 조판, WebView는 Mermaid에만 씁니다.

## 만드는 순서
1. macOS 리더 앱(로컬 파일만). 같은 문서를 QuickMD와 나란히 놓고 가독성을 비교합니다.
2. `mdr` CLI + `serve`. 원격 호스트 Rex 팬 → 링크 → Mac 앱까지 연결합니다.
3. iOS 앱. 같은 Swift Package를 쓰며, Tailscale 연결이 필요합니다.

## 원의 결정 대기
1. 프로젝트 위치와 이름(예: `~/src/mdr`, 앱 이름 "mdr")
2. 1단계에서 QuickMD와 비교할 기준 마크다운 문서 2~3개

## 아직 확인하지 않은 것
- iPhone에서 Tailscale이 꺼져 있을 때의 사용자 경험(원격 문서를 열 수 없음)을 받아들일지
- CLI 바이너리 언어(Go 또는 Rust)
