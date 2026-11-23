import XCTest
@testable import MdrKit

final class RemoteLocationTests: XCTestCase {
    private func location(_ text: String) throws -> RemoteLocation {
        try RemoteLocation(url: XCTUnwrap(URL(string: text)))
    }

    func testParsesLinkAndBuildsRequestURLs() throws {
        let parsed = try location("mdr://100.101.102.103:6370/AbCdEfGhIjKlMnOpQrStUv/docs/%ED%95%9C%EA%B8%80%20%EB%AC%B8%EC%84%9C.md")
        XCTAssertEqual(parsed.host, "100.101.102.103")
        XCTAssertEqual(parsed.port, 6370)
        XCTAssertEqual(parsed.token, "AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertEqual(parsed.components, ["docs", "한글 문서.md"])
        XCTAssertEqual(parsed.fileName, "한글 문서.md")
        XCTAssertEqual(parsed.fileURL.absoluteString,
                       "http://100.101.102.103:6370/v1/AbCdEfGhIjKlMnOpQrStUv/files/docs/%ED%95%9C%EA%B8%80%20%EB%AC%B8%EC%84%9C.md")
        XCTAssertEqual(parsed.eventsURL.absoluteString,
                       "http://100.101.102.103:6370/v1/AbCdEfGhIjKlMnOpQrStUv/events/docs/%ED%95%9C%EA%B8%80%20%EB%AC%B8%EC%84%9C.md")
        XCTAssertEqual(try RemoteLocation(url: parsed.url), parsed)
    }

    func testAcceptsTailnetIPv6() throws {
        let parsed = try location("mdr://[fd7a:115c:a1e0::1234:5678]:6370/tok/a.md")
        XCTAssertEqual(parsed.host, "fd7a:115c:a1e0::1234:5678")
        XCTAssertEqual(parsed.fileURL.absoluteString, "http://[fd7a:115c:a1e0::1234:5678]:6370/v1/tok/files/a.md")
        XCTAssertEqual(try RemoteLocation(url: parsed.url), parsed)
    }

    /// 링크는 믿을 수 없는 입력입니다. tailnet 주소가 아닌 host로는 요청을 만들지 않습니다.
    func testRejectsHostsOutsideTailnet() {
        let hosts = [
            "evil.example.com", "localhost", "host-b", "host-b.example.ts.net", "100.101.102.103.evil.com",
            "127.0.0.1", "192.168.1.23", "10.0.0.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "169.254.169.254",
            "0x64.101.102.103", "100.077.102.103", "1684366951", "[::1]", "[fd7a:115c:a1e1::1]", "[2001:db8::1]",
        ]
        for host in hosts {
            guard let url = URL(string: "mdr://\(host):6370/tok/a.md") else { continue }
            XCTAssertThrowsError(try RemoteLocation(url: url), host) { error in
                guard case .hostNotAllowed = error as? RemoteLocation.LinkError else {
                    return XCTFail("\(host): \(error)")
                }
            }
        }
        XCTAssertFalse(Tailnet.isTailnetAddress(""))
        XCTAssertTrue(Tailnet.isTailnetAddress("100.64.0.0"))
        XCTAssertTrue(Tailnet.isTailnetAddress("100.127.255.255"))
    }

    func testRejectsMalformedLinks() {
        let links = [
            "http://100.101.102.103:6370/tok/a.md",          // 다른 scheme
            "mdr://100.101.102.103/tok/a.md",                // 포트 없음
            "mdr://100.101.102.103:6370/tok",                // 경로 없음
            "mdr://100.101.102.103:6370/tok/",
            "mdr://100.101.102.103:6370//a.md",              // token 없음
            "mdr://100.101.102.103:6370/tok/../a.md",
            "mdr://100.101.102.103:6370/tok/%2e%2e/a.md",
            "mdr://100.101.102.103:6370/tok/..%2Fa.md",
            "mdr://100.101.102.103:6370/tok/a%5Cb.md",
            "mdr://100.101.102.103:6370/tok/a%00.md",
            "mdr://100.101.102.103:6370/tok/dir//a.md",
            "mdr://100.101.102.103:6370/to%2Fk/a.md",        // token에 다른 글자
            "mdr://user@100.101.102.103:6370/tok/a.md",
            "mdr://100.101.102.103:6370/tok/a.md?x=1",
            "mdr://100.101.102.103:6370/tok/a.md#frag",
            "mdr://100.101.102.103:0/tok/a.md",
        ]
        for link in links {
            guard let url = URL(string: link) else { continue }
            XCTAssertThrowsError(try RemoteLocation(url: url), link)
        }
    }

    func testResolvesRelativeReferencesInsideRootOnly() throws {
        let document = try location("mdr://100.101.102.103:6370/tok/guide/intro/readme.md")
        XCTAssertEqual(document.resolving("images/a.png")?.path, "guide/intro/images/a.png")
        XCTAssertEqual(document.resolving("./other.md")?.path, "guide/intro/other.md")
        XCTAssertEqual(document.resolving("../next.md")?.path, "guide/next.md")
        XCTAssertEqual(document.resolving("../../top.md#section")?.path, "top.md")
        XCTAssertEqual(document.resolving("my%20doc.md?raw=1")?.path, "guide/intro/my doc.md")
        XCTAssertEqual(document.resolving("한글.png")?.path, "guide/intro/한글.png")
        // 같은 서버, 같은 token으로만 풀립니다.
        XCTAssertEqual(document.resolving("a.png").map { $0.sharesRoot(with: document) }, true)

        for outside in [
            "../../../secret.md", "../../../../etc/passwd", "..%2F..%2F..%2Fsecret.md", "%2e%2e/%2e%2e/%2e%2e/secret.md",
            "/etc/passwd", "/guide/next.md", "\\\\server\\share", "file:///etc/passwd", "http://evil.example.com/a.png",
            "https://evil.example.com/a.png", "mdr://100.1.2.3:1/other/a.md", "data:image/png;base64,AAAA", "javascript:alert(1)",
            "", "#top", "a\\..\\b.md",
        ] {
            XCTAssertNil(document.resolving(outside), outside)
        }
    }
}

final class LinkPolicyTests: XCTestCase {
    private let local = DocumentSource.file(URL(fileURLWithPath: "/Users/me/docs/readme.md"))
    private let remote = DocumentSource.remote(try! RemoteLocation(url: URL(string: "mdr://100.101.102.103:6370/tok/docs/readme.md")!))

    private func action(_ link: String, in source: DocumentSource?) -> LinkAction {
        LinkPolicy.action(for: URL(string: link)!, in: source)
    }

    func testWebAndMailLinksOpenExternallyFromAnyDocument() {
        for source in [local, remote, nil] {
            for link in ["https://example.com/a", "http://example.com", "mailto:a@example.com", "HTTPS://EXAMPLE.COM"] {
                XCTAssertEqual(action(link, in: source), .openExternally(URL(string: link)!))
            }
        }
    }

    func testOtherSchemesAreDenied() {
        for source in [local, remote, nil] {
            for link in ["javascript:alert(1)", "shortcuts://run-shortcut?name=x", "x-apple.systempreferences:", "ssh://host", "tel:119",
                         "smb://server/share", "vnc://host", "data:text/html,hi", "ftp://example.com/a"] {
                XCTAssertEqual(action(link, in: source), .deny, link)
            }
        }
    }

    func testLocalDocumentOpensMarkdownAndOnlyRevealsOtherFiles() {
        XCTAssertEqual(action("file:///Users/me/docs/other.md", in: local), .openDocument(.file(URL(string: "file:///Users/me/docs/other.md")!)))
        XCTAssertEqual(action("file:///Applications/Calculator.app", in: local), .reveal(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertEqual(action("file:///Users/me/run.command", in: local), .reveal(URL(string: "file:///Users/me/run.command")!))
        // 로컬 문서에 적힌 원격 링크는 열지 않습니다.
        XCTAssertEqual(action("mdr://100.101.102.103:6370/tok/docs/other.md", in: local), .deny)
    }

    /// 원격 문서의 내용은 믿을 수 없는 입력입니다. 로컬 파일을 건드리거나 다른 서버로 보내지 못합니다.
    func testRemoteDocumentCannotTouchLocalFilesOrOtherServers() throws {
        XCTAssertEqual(action("file:///Users/me/docs/other.md", in: remote), .deny)
        XCTAssertEqual(action("file:///Applications/Calculator.app", in: remote), .deny)
        XCTAssertEqual(action("file:///etc/passwd", in: remote), .deny)

        let sibling = try RemoteLocation(url: URL(string: "mdr://100.101.102.103:6370/tok/docs/other.md")!)
        XCTAssertEqual(action("mdr://100.101.102.103:6370/tok/docs/other.md", in: remote), .openDocument(.remote(sibling)))
        for link in [
            "mdr://100.101.102.104:6370/tok/docs/other.md",       // 다른 기기
            "mdr://100.101.102.103:6371/tok/docs/other.md",       // 다른 포트
            "mdr://100.101.102.103:6370/other-token/docs/other.md",
            "mdr://evil.example.com:6370/tok/docs/other.md",
            "mdr://100.101.102.103:6370/tok/docs/data.csv",       // 마크다운이 아님
            "mdr://100.101.102.103:6370/tok/docs/photo.png",
            "mdr://100.101.102.103:6370/tok/../other.md",
        ] {
            XCTAssertEqual(action(link, in: remote), .deny, link)
        }
    }

    func testAnchorsStayInsideDocument() {
        let value = LinkPolicy.linkValue(for: "#설치-방법", in: remote)
        XCTAssertEqual((value as? URL).map { LinkPolicy.action(for: $0, in: remote) }, .anchor("설치-방법"))
    }

    func testRelativeLinksResolveAgainstTheDocumentSource() throws {
        XCTAssertEqual((LinkPolicy.linkValue(for: "sub/other.md", in: local) as? URL)?.path, "/Users/me/docs/sub/other.md")
        XCTAssertEqual((LinkPolicy.linkValue(for: "../guide/next.md", in: remote) as? URL)?.absoluteString,
                       "mdr://100.101.102.103:6370/tok/guide/next.md")
        // 문서 폴더 밖을 가리키는 상대 경로는 링크가 되지 못합니다(글자 그대로 남아 눌러도 열리지 않습니다).
        XCTAssertTrue(LinkPolicy.linkValue(for: "../../secret.md", in: remote) is String)
        XCTAssertTrue(LinkPolicy.linkValue(for: "/etc/passwd", in: remote) is String)
        // 절대 주소는 그대로 두고, 누를 때 규칙이 판단합니다.
        let absolute = try XCTUnwrap(LinkPolicy.linkValue(for: "file:///etc/passwd", in: remote) as? URL)
        XCTAssertEqual(LinkPolicy.action(for: absolute, in: remote), .deny)
    }
}

final class RemoteProtocolTests: XCTestCase {
    func testErrorsMapToUserFacingReasons() {
        XCTAssertEqual(RemoteError.from(status: 401, code: "invalid_token"), .linkExpired)
        XCTAssertEqual(RemoteError.from(status: 403, code: "forbidden_peer"), .peerNotAllowed)
        XCTAssertEqual(RemoteError.from(status: 403, code: "path_not_allowed"), .pathNotAllowed)
        XCTAssertEqual(RemoteError.from(status: 404, code: "not_found"), .notFound)
        XCTAssertEqual(RemoteError.from(status: 500, code: nil), .server(status: 500))
        // 연결이 안 될 때는 Tailscale이 꺼져 있는지를 먼저 알립니다.
        XCTAssertEqual(RemoteError.connectionFailure(host: "100.101.102.103", port: 6370, hasTailnet: false), .tailscaleOff)
        XCTAssertEqual(RemoteError.connectionFailure(host: "100.101.102.103", port: 6370, hasTailnet: true),
                       .unreachable(host: "100.101.102.103", port: 6370))
        XCTAssertEqual(RemoteError.tailscaleOff.title, "Tailscale 연결이 필요합니다")
        XCTAssertTrue(RemoteError.tailscaleOff.isRetryable)
        XCTAssertTrue(RemoteError.unreachable(host: "h", port: 1).isRetryable)
        XCTAssertFalse(RemoteError.linkExpired.isRetryable)
        XCTAssertTrue(RemoteError.linkExpired.detail.contains("mdr <파일>"))
    }

    func testParsesServerSentEvents() {
        var parser = ServerSentEventParser()
        let lines = [
            "event: hello", #"data: {"etag":"\"1-2\""}"#, "",
            ": ping", "",
            "event: change", #"data: {"etag":"\"3-4\""}"#, "",
            "event: unknown", "data: {}", "",
            "data: {}",
        ]
        XCTAssertEqual(lines.compactMap { parser.consume(line: $0) },
                       [.hello(etag: "\"1-2\""), .ping, .change(etag: "\"3-4\"")])
    }

    func testPositionKeyDoesNotDependOnTokenOrPort() {
        XCTAssertEqual(RemoteDocumentFeed.positionKey(host: "100.101.102.103", documentID: "abc", path: "a/b.md"), "mdr://100.101.102.103/id/abc")
        XCTAssertEqual(RemoteDocumentFeed.positionKey(host: "100.101.102.103", documentID: nil, path: "a/b.md"), "mdr://100.101.102.103/path/a/b.md")
    }
}

final class AnchorMappingTests: XCTestCase {
    func testAnchorFollowsItsParagraphWhenTextAboveChanges() {
        let old = "첫 문단\n\u{FFFC}\n둘째 문단\n셋째 문단\n"
        let new = "첫 문단\n[이미지: 없는 그림]\n둘째 문단\n셋째 문단\n"
        let second = (old as NSString).range(of: "둘째").location
        let third = (old as NSString).range(of: "셋째").location
        XCTAssertEqual(TextAnchorMapping.remap(second, from: old, to: new), (new as NSString).range(of: "둘째").location)
        XCTAssertEqual(TextAnchorMapping.remap(third, from: old, to: new), (new as NSString).range(of: "셋째").location)
        // 바뀐 곳보다 앞은 그대로입니다.
        XCTAssertEqual(TextAnchorMapping.remap(0, from: old, to: new), 0)
        XCTAssertEqual(TextAnchorMapping.remap(2, from: old, to: new), 2)
        // 줄어드는 쪽도 같습니다.
        XCTAssertEqual(TextAnchorMapping.remap((new as NSString).range(of: "셋째").location, from: new, to: old), third)
    }

    func testAnchorStaysWhenTextIsAppendedOrUnchanged() {
        let old = "하나\n둘\n셋\n"
        XCTAssertEqual(TextAnchorMapping.remap(3, from: old, to: old), 3)
        XCTAssertEqual(TextAnchorMapping.remap(3, from: old, to: old + "넷\n"), 3)
        XCTAssertEqual(TextAnchorMapping.remap(5, from: old, to: old + "넷\n"), 5)
        // 읽던 곳이 지워지면 그 자리에 머뭅니다(새 글의 범위 안).
        XCTAssertLessThanOrEqual(TextAnchorMapping.remap(5, from: old, to: "하나\n"), 3)
        XCTAssertEqual(TextAnchorMapping.remap(4, from: "", to: "새 글"), 4 + 3)
    }
}
