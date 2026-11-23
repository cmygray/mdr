import Foundation

/// 원격 문서를 가져오지 못한 이유입니다. `title`과 `detail`을 그대로 화면에 보여 줍니다.
public enum RemoteError: Error, Equatable, Sendable {
    /// 이 기기의 Tailscale이 꺼져 있습니다.
    case tailscaleOff
    /// Tailscale은 켜져 있지만 서버가 응답하지 않습니다.
    case unreachable(host: String, port: Int)
    /// token이 만료되었거나 올바르지 않습니다(401).
    case linkExpired
    /// 서버가 이 기기를 받아 주지 않습니다(403 forbidden_peer).
    case peerNotAllowed
    /// 문서 폴더 밖이거나 내주지 않는 종류의 파일입니다(403 path_not_allowed).
    case pathNotAllowed
    /// 파일이 없습니다(404).
    case notFound
    /// 그 밖의 응답
    case server(status: Int)
    /// 응답이 받을 수 있는 크기를 넘습니다.
    case tooLarge

    public var title: String {
        switch self {
        case .tailscaleOff: return "Tailscale 연결이 필요합니다"
        case .unreachable: return "서버에 연결할 수 없습니다"
        case .linkExpired: return "링크가 만료되었습니다"
        case .peerNotAllowed: return "이 기기는 허용되지 않았습니다"
        case .pathNotAllowed: return "열 수 없는 경로입니다"
        case .notFound: return "문서를 찾을 수 없습니다"
        case .server: return "서버가 문서를 내주지 않았습니다"
        case .tooLarge: return "문서가 너무 큽니다"
        }
    }

    public var detail: String {
        switch self {
        case .tailscaleOff:
            return "원격 문서는 Tailscale로만 가져옵니다. 이 기기의 Tailscale을 켜면 자동으로 다시 시도합니다."
        case .unreachable(let host, let port):
            return "\(host):\(port)의 mdr 서버가 응답하지 않습니다. 원격 호스트가 켜져 있고 Tailscale에 연결돼 있는지 확인해 주십시오. "
                + "서버가 끝났다면 원격 호스트에서 mdr <파일>을 다시 실행해 새 링크를 받으십시오."
        case .linkExpired:
            return "이 링크의 token이 만료되었거나 서버가 다시 시작됐습니다. 원격 호스트에서 mdr <파일>을 다시 실행해 새 링크를 받으십시오."
        case .peerNotAllowed:
            return "서버는 자기 주인의 Tailscale 계정에 속한 기기만 받습니다. 이 기기와 원격 호스트가 같은 계정으로 Tailscale에 로그인했는지 확인해 주십시오."
        case .pathNotAllowed:
            return "서버는 문서 폴더 안의 마크다운과 이미지만 내줍니다."
        case .notFound:
            return "원격 호스트에서 파일이 지워졌거나 이름이 바뀌었습니다."
        case .server(let status):
            return "서버가 HTTP \(status)로 응답했습니다."
        case .tooLarge:
            return "원격 문서는 \(RemoteClient.documentLimit / 1_048_576)MB까지 엽니다."
        }
    }

    /// 기다리면 나아질 수 있는 문제인지. 그렇다면 자동으로 다시 시도합니다.
    public var isRetryable: Bool {
        switch self {
        case .tailscaleOff, .unreachable, .server: return true
        case .linkExpired, .peerNotAllowed, .pathNotAllowed, .notFound, .tooLarge: return false
        }
    }

    /// HTTP 상태와 서버가 준 오류 코드로 이유를 정합니다.
    public static func from(status: Int, code: String?) -> RemoteError {
        switch (status, code) {
        case (401, _): return .linkExpired
        case (403, "path_not_allowed"): return .pathNotAllowed
        case (403, _): return .peerNotAllowed
        case (404, _): return .notFound
        default: return .server(status: status)
        }
    }

    /// 연결 자체가 실패했을 때의 이유입니다. Tailscale이 꺼져 있으면 그것을 먼저 알립니다.
    public static func connectionFailure(host: String, port: Int, hasTailnet: Bool) -> RemoteError {
        hasTailnet ? .unreachable(host: host, port: port) : .tailscaleOff
    }
}

/// 서버가 변경 알림 연결로 보내는 것입니다.
public enum RemoteEvent: Equatable, Sendable {
    /// 연결 직후의 현재 상태
    case hello(etag: String)
    /// 파일이 바뀜
    case change(etag: String)
    /// 연결이 살아 있음을 알리는 주석 줄
    case ping
}

/// SSE 줄을 이벤트로 바꿉니다. 줄을 차례로 넣으면 이벤트가 완성될 때 돌려줍니다.
public struct ServerSentEventParser {
    private var name: String?

    public init() {}

    public mutating func consume(line: String) -> RemoteEvent? {
        if line.hasPrefix(":") { return .ping }
        if line.isEmpty {
            name = nil
            return nil
        }
        if line.hasPrefix("event:") {
            name = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:"), let name else { return nil }
        self.name = nil
        let payload = Data(line.dropFirst("data:".count).utf8)
        let etag = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["etag"] as? String ?? ""
        switch name {
        case "hello": return .hello(etag: etag)
        case "change": return .change(etag: etag)
        default: return nil
        }
    }
}

/// `mdr serve`와 이야기하는 HTTP 클라이언트입니다. 프로토콜은 `cli/internal/server/server.go` 머리말에 있습니다.
public final class RemoteClient: @unchecked Sendable {
    public struct File: Sendable {
        public let data: Data
        public let etag: String?
        /// 서버가 문서 경로에서 만든 이름표. 읽던 자리의 키로 씁니다.
        public let documentID: String?
        public let hostName: String?
    }

    public enum Fetch: Sendable {
        case notModified
        case file(File)
    }

    /// 받을 수 있는 크기입니다. 서버와 문서는 믿을 수 없는 입력이므로 끝없이 받지 않습니다.
    public static let documentLimit = 64 * 1_048_576
    public static let imageLimit = 64 * 1_048_576
    /// 변경 알림 한 줄의 최대 길이
    static let eventLineLimit = 64 * 1024

    /// 서버가 다른 주소로 넘기는 응답은 따르지 않습니다. 앱은 링크에 적힌 tailnet 주소하고만 이야기합니다.
    private class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// 응답을 모으되, 정해 둔 크기를 넘으면 그 자리에서 끊습니다.
    private final class Collector: Delegate, URLSessionDataDelegate {
        private struct Pending {
            var data = Data()
            var limit: Int
            var response: URLResponse?
            var overflowed = false
            var continuation: CheckedContinuation<(Data, URLResponse), Error>
        }

        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(_ task: URLSessionTask, limit: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.lock()
            pending[task.taskIdentifier] = Pending(limit: limit, continuation: continuation)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            pending[dataTask.taskIdentifier]?.response = response
            let limit = pending[dataTask.taskIdentifier]?.limit ?? 0
            let tooLarge = response.expectedContentLength > Int64(limit)
            if tooLarge { pending[dataTask.taskIdentifier]?.overflowed = true }
            lock.unlock()
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            var overflowed = false
            if var entry = pending[dataTask.taskIdentifier] {
                if entry.data.count + data.count > entry.limit {
                    entry.overflowed = true
                    entry.data = Data()
                    overflowed = true
                } else if !entry.overflowed {
                    entry.data.append(data)
                }
                pending[dataTask.taskIdentifier] = entry
            }
            lock.unlock()
            if overflowed { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let entry = pending.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            guard let entry else { return }
            if entry.overflowed {
                entry.continuation.resume(throwing: RemoteError.tooLarge)
            } else if let error {
                entry.continuation.resume(throwing: error)
            } else if let response = entry.response {
                entry.continuation.resume(returning: (entry.data, response))
            } else {
                entry.continuation.resume(throwing: RemoteError.server(status: 0))
            }
        }
    }

    private let collector = Collector()
    private let session: URLSession
    private let streamSession: URLSession
    private let hasTailnet: @Sendable () -> Bool

    /// - Parameters:
    ///   - hasTailnet: 이 기기의 Tailscale이 켜져 있는지 묻는 함수. 테스트에서 바꿔 끼웁니다.
    ///   - protocolClasses: 테스트에서 네트워크 대신 쓸 `URLProtocol`
    public init(hasTailnet: @escaping @Sendable () -> Bool = Tailnet.hasLocalInterface, protocolClasses: [AnyClass]? = nil) {
        self.hasTailnet = hasTailnet
        func configuration(idleTimeout: TimeInterval) -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = idleTimeout
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            // 시스템 프록시를 거치지 않고 tailnet 주소로 바로 갑니다.
            configuration.connectionProxyDictionary = [:]
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            return configuration
        }
        session = URLSession(configuration: configuration(idleTimeout: 10), delegate: collector, delegateQueue: nil)
        // 서버는 15초마다 주석 줄을 보냅니다. 40초 동안 아무것도 오지 않으면 끊긴 것으로 봅니다.
        streamSession = URLSession(configuration: configuration(idleTimeout: 40), delegate: Delegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    private func failure(_ error: Error, _ location: RemoteLocation) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let remote = error as? RemoteError { return remote }
        return RemoteError.connectionFailure(host: location.host, port: location.port, hasTailnet: hasTailnet())
    }

    private func check(_ response: URLResponse, body: Data?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw RemoteError.server(status: 0) }
        if http.statusCode == 200 || http.statusCode == 304 { return http }
        let code = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
        throw RemoteError.from(status: http.statusCode, code: code)
    }

    /// 요청 하나를 보내 응답을 `limit` 바이트까지 모읍니다.
    private func collect(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.register(task, limit: limit, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 서버가 준 문서 이름표는 16진수 글자일 때만 씁니다. 읽던 자리의 키에 그대로 들어가기 때문입니다.
    static func validDocumentID(_ value: String?) -> String? {
        guard let value, (16...64).contains(value.count),
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return value
    }

    /// 파일을 가져옵니다. `ifNoneMatch`와 같으면 내용을 받지 않습니다. 실패하면 `RemoteError`를 던집니다.
    public func fetch(_ location: RemoteLocation, ifNoneMatch etag: String? = nil, limit: Int = RemoteClient.documentLimit) async throws -> Fetch {
        // Tailscale이 꺼져 있으면 연결을 시도하지 않습니다. 시도하면 시간 초과까지 기다리게 됩니다.
        guard hasTailnet() else { throw RemoteError.tailscaleOff }
        var request = URLRequest(url: location.fileURL)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await collect(request, limit: limit)
            let http = try check(response, body: data)
            if http.statusCode == 304 { return .notModified }
            return .file(File(
                data: data,
                etag: http.value(forHTTPHeaderField: "ETag"),
                documentID: Self.validDocumentID(http.value(forHTTPHeaderField: "X-Mdr-Doc-Id")),
                hostName: (http.value(forHTTPHeaderField: "X-Mdr-Host")?.removingPercentEncoding).map { String($0.prefix(64)) }
            ))
        } catch {
            throw failure(error, location)
        }
    }

    /// 변경 알림 연결을 엽니다. 연결이 끊기면 `RemoteError`를 던지며 끝납니다.
    public func events(for location: RemoteLocation) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard self.hasTailnet() else { throw RemoteError.tailscaleOff }
                    var request = URLRequest(url: location.eventsURL)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await self.streamSession.bytes(for: request)
                    if (response as? HTTPURLResponse)?.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes.prefix(4096) { body.append(byte) }
                        _ = try self.check(response, body: body)
                    }
                    // 줄을 직접 나눕니다. 줄바꿈 없이 끝없이 보내는 서버 때문에 메모리가 차지 않게, 한 줄의 길이를 제한합니다.
                    var parser = ServerSentEventParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        if byte != 0x0A {
                            line.append(byte)
                            if line.count > Self.eventLineLimit { throw RemoteError.server(status: 200) }
                            continue
                        }
                        if line.last == 0x0D { line.removeLast() }
                        if let event = parser.consume(line: String(decoding: line, as: UTF8.self)) {
                            continuation.yield(event)
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    // 서버가 연결을 닫았습니다(서버가 끝났을 때).
                    throw RemoteError.unreachable(host: location.host, port: location.port)
                } catch {
                    continuation.finish(throwing: self.failure(error, location))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
