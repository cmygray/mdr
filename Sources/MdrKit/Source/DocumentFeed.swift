import Foundation
import os

private let feedLog = Logger(subsystem: "kim.two.mdr", category: "scroll")

/// 문서의 한 시점 내용입니다.
public struct DocumentSnapshot {
    public let data: Data
    /// 읽던 자리를 기억하는 키입니다. 같은 문서는 다시 열어도 같은 값입니다.
    public let positionKey: String
    /// 원격 문서이면 서버 기기의 이름
    public let hostName: String?
}

public enum FeedState: Equatable {
    /// 처음 가져오는 중
    case loading
    /// 문서를 받았고 변경도 받고 있음
    case live
    /// 문서를 한 번도 받지 못함
    case failed(RemoteError)
    /// 문서는 받았지만 지금은 변경을 받지 못함
    case stale(RemoteError)
}

/// 문서의 내용과 그 변경을 내주는 쪽입니다. 로컬 파일과 원격 서버가 같은 모양으로 보입니다.
///
/// 앱(macOS, iOS)은 이 프로토콜만 보고 문서를 그립니다. 콜백은 모두 메인 스레드에서 부릅니다.
public protocol DocumentFeed: AnyObject {
    var source: DocumentSource { get }
    /// 이 문서의 이미지 참조를 푸는 쪽
    var images: ImageProviding { get }
    var state: FeedState { get }
    /// 문서를 처음 받았을 때와 바뀔 때마다 부릅니다.
    var onSnapshot: ((DocumentSnapshot) -> Void)? { get set }
    var onState: ((FeedState) -> Void)? { get set }
    /// 가져오기와 변경 감시를 시작합니다.
    func start()
    func stop()
    /// 지금 바로 다시 가져옵니다.
    func retry()
}

// MARK: - Local file

/// 로컬 파일입니다. 파일이 바뀌면 다시 읽어 알립니다.
public final class FileDocumentFeed: DocumentFeed {
    public let url: URL
    public var source: DocumentSource { .file(url) }
    public let images: ImageProviding
    public let state: FeedState = .live
    public var onSnapshot: ((DocumentSnapshot) -> Void)?
    public var onState: ((FeedState) -> Void)?

    private let lock = NSLock()
    /// 가장 최근에 읽은 내용입니다. 감시 알림이 왔을 때 실제로 바뀌었는지 가려냅니다.
    private var loaded: Data?
    private var watcher: FileWatcher?

    public init(url: URL) {
        self.url = url
        images = LocalImageProvider(baseURL: url)
    }

    public var positionKey: String { url.standardizedFileURL.path }

    /// 파일을 지금 읽습니다. 앱이 문서를 열 때, 창을 만드는 동안 백그라운드에서 부릅니다.
    public func read() throws -> DocumentSnapshot {
        let data = try Data(contentsOf: url)
        lock.lock()
        loaded = data
        lock.unlock()
        return DocumentSnapshot(data: data, positionKey: positionKey, hostName: nil)
    }

    public func start() {
        guard watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
        lock.lock()
        let needsFirstRead = loaded == nil
        lock.unlock()
        if needsFirstRead { reload() }
    }

    public func stop() {
        watcher = nil
    }

    public func retry() {
        reload()
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let data = try? Data(contentsOf: self.url) else { return }
            // 파일을 열기만 해도 속성 변경 알림이 옵니다. 내용이 같으면 아무것도 하지 않습니다.
            self.lock.lock()
            let unchanged = self.loaded == data
            if !unchanged { self.loaded = data }
            self.lock.unlock()
            guard !unchanged else { return }
            let snapshot = DocumentSnapshot(data: data, positionKey: self.positionKey, hostName: nil)
            DispatchQueue.main.async { self.onSnapshot?(snapshot) }
        }
    }
}

// MARK: - Remote server

/// `mdr serve`가 내주는 원격 문서입니다.
///
/// 문서를 가져온 뒤 변경 알림 연결(SSE)을 열어 두고, 바뀌었다는 알림이 오면 다시 가져옵니다.
/// 연결이 끊기면 간격을 늘려 가며 다시 붙고, 붙은 직후에 그 사이 바뀐 것이 있는지 확인합니다.
/// 기다려도 나아지지 않는 문제(링크 만료, 파일 없음)에서는 멈추고 `retry()`를 기다립니다.
public final class RemoteDocumentFeed: DocumentFeed {
    public let location: RemoteLocation
    public var source: DocumentSource { .remote(location) }
    public var images: ImageProviding { imageStore }
    public let imageStore: RemoteImageStore
    public private(set) var state: FeedState = .loading
    public var onSnapshot: ((DocumentSnapshot) -> Void)?
    public var onState: ((FeedState) -> Void)?

    private let client: RemoteClient
    private var task: Task<Void, Never>?
    private var etag: String?
    private var loaded: Data?
    private var documentID: String?
    private var hostName: String?

    /// 다시 붙기 전에 기다리는 시간의 처음 값과 최댓값(초)
    private let retryDelay: (first: Double, max: Double)

    public init(location: RemoteLocation, client: RemoteClient = RemoteClient(), retryDelay: (first: Double, max: Double) = (1, 30)) {
        self.location = location
        self.client = client
        self.retryDelay = retryDelay
        imageStore = RemoteImageStore(document: location, client: client)
    }

    deinit {
        task?.cancel()
    }

    public var positionKey: String {
        Self.positionKey(host: location.host, documentID: documentID, path: location.path)
    }

    /// 읽던 자리의 키입니다. token과 포트는 서버가 다시 뜨면 바뀌므로 넣지 않습니다.
    /// 서버가 문서 경로에서 만든 이름표를 쓰고, 없으면(옛 서버) 링크의 경로를 씁니다.
    public static func positionKey(host: String, documentID: String?, path: String) -> String {
        if let documentID, !documentID.isEmpty { return "mdr://\(host)/id/\(documentID)" }
        return "mdr://\(host)/path/\(path)"
    }

    /// 서버 기기의 이름입니다. 문서를 한 번 받은 뒤에 알 수 있습니다.
    public var remoteHostName: String? { hostName }

    public func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func retry() {
        stop()
        if loaded == nil { set(.loading) }
        start()
    }

    private func set(_ next: FeedState) {
        guard next != state else { return }
        state = next
        onState?(next)
    }

    @MainActor
    private func run() async {
        var delay = retryDelay.first
        while !Task.isCancelled {
            do {
                try await refresh()
                set(.live)
                delay = retryDelay.first
                for try await event in client.events(for: location) {
                    switch event {
                    case .hello(let current), .change(let current):
                        // 연결 직후의 `hello`는, 문서를 받은 뒤 연결하기까지 사이에 바뀐 것을 잡아 줍니다.
                        if current != etag { try await refresh() }
                    case .ping:
                        feedLog.debug("ping")
                        break
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                let reason = error as? RemoteError ?? .unreachable(host: location.host, port: location.port)
                set(loaded == nil ? .failed(reason) : .stale(reason))
                guard reason.isRetryable else { return }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, retryDelay.max)
        }
    }

    @MainActor
    private func refresh() async throws {
        guard case .file(let file) = try await client.fetch(location, ifNoneMatch: loaded == nil ? nil : etag) else { return }
        etag = file.etag
        documentID = file.documentID ?? documentID
        hostName = file.hostName ?? hostName
        // 저장만 다시 한 경우처럼 내용이 같으면 다시 그리지 않습니다.
        feedLog.info("refresh etag changed, same data=\(file.data == self.loaded)")
        guard file.data != loaded else { return }
        let isFirst = loaded == nil
        loaded = file.data
        if !isFirst { imageStore.revalidate() }
        onSnapshot?(DocumentSnapshot(data: file.data, positionKey: positionKey, hostName: hostName))
    }
}
