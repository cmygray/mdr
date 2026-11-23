import AppKit
import MdrKit

/// 읽기 전용 마크다운 문서입니다. 로컬 파일이거나 `mdr serve`가 내주는 원격 문서이고, 바뀌면 다시 그립니다.
///
/// 내용과 그 변경은 `DocumentFeed`(MdrKit)가 내줍니다. 이 클래스는 받은 내용을 백그라운드에서 파싱해
/// 창에 넘기는 일만 합니다. 로컬 파일은 `read(from:)`가 파일 내용만 읽고 바로 돌아가므로,
/// AppKit이 창을 만드는 동안 파싱이 함께 진행됩니다.
final class Document: NSDocument {
    struct Content {
        var parsed: MarkdownDocument
        var script: Script
        var byteCount: Int
    }

    /// 화면에 쓰고 있는 내용입니다. 메인 스레드에서만 읽고 씁니다.
    private(set) var content: Content?
    private var contentWaiters: [() -> Void] = []

    /// 백그라운드 파싱 결과를 메인 스레드로 넘기는 자리입니다.
    private let parseCondition = NSCondition()
    private var parsedContent: Content?
    private var parsedGeneration = 0
    private var adoptedGeneration = 0

    /// 문서의 출처입니다. 로컬 파일은 `read(from:)`에서, 원격 문서는 `init(remote:client:)`에서 정해집니다.
    private(set) var feed: DocumentFeed?
    /// 읽던 자리를 기억하는 키입니다. 원격 문서는 처음 받은 뒤에 정해집니다.
    private(set) var positionKey: String?
    /// 원격 문서를 내준 기기의 이름
    private(set) var remoteHostName: String?

    var source: DocumentSource? { feed?.source }

    override class var autosavesInPlace: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    /// 원격 문서를 엽니다. 내용은 창을 띄운 뒤에 도착합니다.
    convenience init(remote location: RemoteLocation, client: RemoteClient) {
        self.init()
        feed = RemoteDocumentFeed(location: location, client: client)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let feed = FileDocumentFeed(url: url)
        let snapshot = try feed.read()
        LaunchClock.mark("read")
        self.feed = feed
        positionKey = snapshot.positionKey
        parse(snapshot.data)
    }

    override var displayName: String! {
        get {
            if case .remote(let location) = source { return location.fileName }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    private func parse(_ data: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = String(decoding: data, as: UTF8.self)
            let content = Content(parsed: MarkdownParser.parse(source), script: Script.detect(in: source), byteCount: data.count)
            LaunchClock.mark("parsed")
            guard let self else { return }
            self.parseCondition.lock()
            self.parsedContent = content
            self.parsedGeneration += 1
            self.parseCondition.broadcast()
            self.parseCondition.unlock()
            DispatchQueue.main.async { self.adoptParsedContent() }
        }
    }

    /// 새 파싱 결과가 있으면 받아들이고, 기다리던 쪽과 창에 알립니다. 메인 스레드에서 부릅니다.
    private func adoptParsedContent() {
        parseCondition.lock()
        let latest = parsedContent
        let generation = parsedGeneration
        parseCondition.unlock()
        guard let latest, generation != adoptedGeneration else { return }
        let isReload = content != nil
        adoptedGeneration = generation
        content = latest
        let waiters = contentWaiters
        contentWaiters = []
        waiters.forEach { $0() }
        if isReload {
            readerControllers.forEach { $0.documentDidReload() }
        }
    }

    private var readerControllers: [ReaderWindowController] {
        windowControllers.compactMap { $0 as? ReaderWindowController }
    }

    /// 파싱이 끝났으면 바로, 아니면 끝났을 때 메인 스레드에서 `body`를 부릅니다.
    func whenContentIsReady(_ body: @escaping () -> Void) {
        if content != nil {
            body()
        } else {
            contentWaiters.append(body)
        }
    }

    /// 파싱이 `timeout` 안에 끝나면 그 결과를 바로 받아들입니다. 창을 띄우기 직전에 불러서,
    /// 빈 창이 먼저 보였다가 내용이 뒤늦게 차는 것을 줄입니다. 메인 스레드에서 부릅니다.
    func waitForContent(timeout: TimeInterval) {
        guard content == nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        parseCondition.lock()
        while parsedContent == nil, parseCondition.wait(until: deadline) {}
        parseCondition.unlock()
        adoptParsedContent()
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
        guard let feed else { return }
        feed.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.positionKey = snapshot.positionKey
            self.remoteHostName = snapshot.hostName
            self.readerControllers.forEach { $0.sourceDidUpdate() }
            self.parse(snapshot.data)
        }
        feed.onState = { [weak self] state in
            self?.readerControllers.forEach { $0.feedStateDidChange(state) }
        }
        if let remote = feed as? RemoteDocumentFeed {
            // 받지 못한 이미지는 대체 글자로 바꿔 보여 줍니다.
            remote.imageStore.onNeedsRerender = { [weak self] in
                self?.readerControllers.forEach { $0.documentDidReload() }
            }
        }
        feed.start()
    }

    /// 지금 바로 다시 가져옵니다(원격 문서의 "다시 시도").
    func retryLoading() {
        feed?.retry()
    }

    override func close() {
        feed?.stop()
        super.close()
    }

    // 읽기 전용이므로 저장 관련 동작을 모두 막습니다.
    override func data(ofType typeName: String) throws -> Data {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

    override var isDocumentEdited: Bool { false }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(revertToSaved(_:)), #selector(duplicate(_:)),
             #selector(rename(_:)), #selector(move(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// 문서를 여는 한 곳입니다. `mdr://` 링크, 문서 안의 링크가 모두 여기를 거칩니다.
enum DocumentOpener {
    /// 원격 문서들이 함께 쓰는 HTTP 클라이언트
    static let client = RemoteClient(hasTailnet: {
        Automation.shared.assumesTailscaleOff ? false : Tailnet.hasLocalInterface()
    })

    static func open(_ source: DocumentSource) {
        switch source {
        case .file(let url):
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        case .remote(let location):
            openRemote(location)
        }
    }

    /// 바깥에서 들어온 `mdr://` 링크를 엽니다. 받을 수 없는 링크이면 이유를 알립니다.
    static func open(link: URL) {
        do {
            openRemote(try RemoteLocation(url: link))
        } catch {
            let reason: String
            if case RemoteLocation.LinkError.hostNotAllowed(let host) = error {
                reason = "mdr 링크는 Tailscale 주소(100.x.y.z)의 서버만 가리킬 수 있습니다. 이 링크의 서버는 \(host)입니다."
            } else {
                reason = "mdr://<주소>:<포트>/<token>/<경로> 꼴이 아닙니다."
            }
            NSLog("mdr: 열 수 없는 링크 %@ (%@)", link.absoluteString, reason)
            guard !Automation.shared.isActive else {
                Automation.shared.linkWasRejected(reason)
                return
            }
            let alert = NSAlert()
            alert.messageText = "열 수 없는 링크입니다"
            alert.informativeText = reason
            alert.runModal()
        }
    }

    private static func openRemote(_ location: RemoteLocation) {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? Document }
        // 이미 열려 있으면 그 창을 앞으로 가져옵니다. 받지 못하고 있었다면 다시 시도합니다.
        if let existing = documents.first(where: { $0.source == .remote(location) }) {
            if existing.feed?.state != .live { existing.retryLoading() }
            existing.showWindows()
            NSApp.activate()
            return
        }
        // 같은 문서를 죽은 링크로 열어 둔 창이 있으면 닫습니다. 서버가 다시 떠서 새 링크를 받은 경우입니다.
        // 읽던 자리는 token과 상관없는 키로 기억하므로 새 창이 이어받습니다.
        for stale in documents {
            guard case .remote(let other) = stale.source, other.host == location.host, other.path == location.path,
                  !other.sharesRoot(with: location) else { continue }
            switch stale.feed?.state {
            case .failed, .stale: stale.close()
            default: break
            }
        }
        let document = Document(remote: location, client: client)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        NSApp.activate()
    }
}
