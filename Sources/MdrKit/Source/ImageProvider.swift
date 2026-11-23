import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// 문서에 적힌 이미지 참조를 본문에 넣을 첨부로 바꿉니다. 메인 스레드에서 씁니다.
public protocol ImageProviding: AnyObject {
    /// 그릴 수 없는 참조이면 nil입니다. 그때 렌더러는 대체 글자를 보여 줍니다.
    func attachment(for reference: ImageRef) -> ImageAttachment?
}

/// 로컬 문서의 이미지입니다. 문서 파일을 기준으로 상대 경로를 풉니다.
public final class LocalImageProvider: ImageProviding {
    private let baseURL: URL?

    public init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    public func attachment(for reference: ImageRef) -> ImageAttachment? {
        if let url = URL(string: reference.source), let scheme = url.scheme {
            return scheme == "file" ? ImageAttachment(url: url) : nil
        }
        guard let url = Self.fileURL(for: reference.source, relativeTo: baseURL) else { return nil }
        return ImageAttachment(url: url)
    }

    static func fileURL(for path: String, relativeTo baseURL: URL?) -> URL? {
        guard let baseURL else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
    }
}

/// 원격 문서의 이미지입니다. 문서를 먼저 그리고, 이미지는 받는 대로 채웁니다.
///
/// 받은 이미지는 문서가 열려 있는 동안 들고 있습니다. 그래서 문서를 다시 그릴 때(글자 크기 변경, 문서 변경)는
/// 처음부터 제 크기로 들어가 화면이 흔들리지 않습니다. 문서가 바뀌면 `revalidate()`로 이미지도 바뀌었는지 묻습니다.
///
/// 원격 문서의 이미지 참조는 같은 서버의 같은 문서 폴더 안으로만 풉니다. 웹 주소나 `file:` 참조는 받지 않습니다.
public final class RemoteImageStore: ImageProviding {
    private struct Entry {
        var data: Data
        var etag: String?
    }

    private final class Weak {
        weak var attachment: ImageAttachment?
        init(_ attachment: ImageAttachment) { self.attachment = attachment }
    }

    private let document: RemoteLocation
    private let client: RemoteClient
    private var cache: [RemoteLocation: Entry] = [:]
    private var failed: Set<RemoteLocation> = []
    private var loading: Set<RemoteLocation> = []
    /// 화면에 나가 있는 첨부들입니다. 이미지를 받거나 바뀌면 이들을 채웁니다.
    private var shown: [RemoteLocation: [Weak]] = [:]

    /// 받기 전의 빈 상자 색
    public var placeholderTint: PlatformColor = .gray.withAlphaComponent(0.12)
    /// 받지 못한 이미지가 생겨 문서를 다시 그려야 할 때 부릅니다(대체 글자로 바꾸기 위해).
    public var onNeedsRerender: (() -> Void)?

    public private(set) var loadedCount = 0
    public private(set) var failedCount = 0
    public var pendingCount: Int { loading.count }

    public init(document: RemoteLocation, client: RemoteClient) {
        self.document = document
        self.client = client
    }

    public func attachment(for reference: ImageRef) -> ImageAttachment? {
        guard let target = document.resolving(reference.source), !failed.contains(target) else { return nil }
        let attachment: ImageAttachment
        if let entry = cache[target], let ready = ImageAttachment(data: entry.data, name: target.fileName) {
            attachment = ready
        } else {
            attachment = ImageAttachment(pendingNamed: target.fileName, tint: placeholderTint)
            load(target, knownETag: nil)
        }
        shown[target, default: []].removeAll { $0.attachment == nil }
        shown[target, default: []].append(Weak(attachment))
        return attachment
    }

    /// 문서가 바뀌었을 때 부릅니다. 들고 있는 이미지가 서버에서 바뀌었는지 묻고, 실패했던 이미지는 다시 시도하게 합니다.
    public func revalidate() {
        failed.removeAll()
        for (target, entry) in cache {
            load(target, knownETag: entry.etag)
        }
    }

    private func load(_ target: RemoteLocation, knownETag: String?) {
        guard loading.insert(target).inserted else { return }
        Task { @MainActor [weak self, client] in
            let result: Result<RemoteClient.Fetch, Error>
            do {
                result = .success(try await client.fetch(target, ifNoneMatch: knownETag))
            } catch {
                result = .failure(error)
            }
            self?.finish(target, result)
        }
    }

    private func finish(_ target: RemoteLocation, _ result: Result<RemoteClient.Fetch, Error>) {
        loading.remove(target)
        switch result {
        case .success(.notModified):
            return
        case .success(.file(let file)) where ImageAttachment.pixelSize(of: file.data) != nil:
            if cache[target] == nil { loadedCount += 1 }
            cache[target] = Entry(data: file.data, etag: file.etag)
            for box in shown[target] ?? [] {
                box.attachment?.fulfill(with: file.data)
            }
        default:
            // 받지 못했거나 이미지가 아닙니다. 이미 보여 주고 있던 이미지가 있으면 그대로 둡니다.
            guard cache[target] == nil else { return }
            failed.insert(target)
            failedCount += 1
            onNeedsRerender?()
        }
    }
}
