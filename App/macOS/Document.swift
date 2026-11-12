import AppKit
import MdrKit

/// 읽기 전용 마크다운 문서입니다. 파일이 바뀌면 다시 읽습니다.
final class Document: NSDocument {
    private(set) var parsed = MarkdownDocument(blocks: [])
    private(set) var script: Script = .latin
    private(set) var sourceByteCount = 0
    private var watcher: FileWatcher?

    override class var autosavesInPlace: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        let source = String(decoding: data, as: UTF8.self)
        LaunchClock.mark("read")
        let parsed = MarkdownParser.parse(source)
        let script = Script.detect(in: source)
        LaunchClock.mark("parsed")
        self.parsed = parsed
        self.script = script
        sourceByteCount = data.count
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
        guard let fileURL, let type = fileType else { return }
        do {
            try read(from: fileURL, ofType: type)
            for case let controller as ReaderWindowController in windowControllers {
                controller.documentDidReload()
            }
        } catch {
            NSLog("mdr: 문서를 다시 읽지 못했습니다: %@", error.localizedDescription)
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
