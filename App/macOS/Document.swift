import AppKit
import MdrKit

/// 읽기 전용 마크다운 문서입니다. 파일이 바뀌면 다시 읽습니다.
///
/// 파싱은 백그라운드에서 합니다. `read(from:)`는 파일 내용만 읽고 바로 돌아가므로,
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

    private let stateLock = NSLock()
    /// 가장 최근에 읽은 파일 내용입니다. 감시 알림이 왔을 때 실제로 바뀌었는지 가려냅니다.
    private var loadedData: Data?
    private var watcher: FileWatcher?

    override class var autosavesInPlace: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        LaunchClock.mark("read")
        stateLock.lock()
        loadedData = data
        stateLock.unlock()
        parse(data)
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
            for case let controller as ReaderWindowController in windowControllers {
                controller.documentDidReload()
            }
        }
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
        if let fileURL {
            watcher = FileWatcher(url: fileURL) { [weak self] in
                self?.reloadFromDisk()
            }
        }
    }

    private func reloadFromDisk() {
        guard let fileURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let data = try? Data(contentsOf: fileURL) else { return }
            // 파일을 열기만 해도 속성 변경 알림이 옵니다. 내용이 같으면 아무것도 하지 않습니다.
            self.stateLock.lock()
            let unchanged = self.loadedData == data
            if !unchanged { self.loadedData = data }
            self.stateLock.unlock()
            if !unchanged { self.parse(data) }
        }
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
