import Foundation

/// Tailscale이 기기에 주는 주소 범위를 다룹니다.
public enum Tailnet {
    /// `host`가 tailnet 범위(100.64.0.0/10, fd7a:115c:a1e0::/48)의 IP 글자인지 알려 줍니다.
    /// 이름(DNS)은 받지 않습니다. 이름이 가리키는 곳은 바뀔 수 있기 때문입니다.
    public static func isTailnetAddress(_ host: String) -> Bool {
        canonicalAddress(host) != nil
    }

    /// tailnet 범위의 IP 글자이면 표준 꼴로 돌려주고, 아니면 nil입니다. IPv6은 대괄호 없는 소문자 꼴입니다.
    ///
    /// 글자를 먼저 좁게 거릅니다. `inet_pton`은 IPv6 주소 뒤의 `%구역 이름`이나 NUL 뒤의 글자를 무시하고
    /// 성공하므로, 그것만 믿으면 주소가 아닌 글자가 host에 섞여 들어옵니다.
    public static func canonicalAddress(_ host: String) -> String? {
        var text = host
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        if text.contains(".") {
            // 표준 꼴(`100.101.102.103`)만 받습니다. `100.079.1.1`이나 `0x64.…` 같은 꼴은 거절합니다.
            let octets = text.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ part in
                !part.isEmpty && part.count <= 3 && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
                    && (part.count == 1 || part.first != "0")
            }) else { return nil }
            var v4 = in_addr()
            guard inet_pton(AF_INET, text, &v4) == 1, UInt32(bigEndian: v4.s_addr) & 0xFFC0_0000 == 0x6440_0000 else { return nil }
            return text
        }
        guard !text.isEmpty, text.count <= 39, text.unicodeScalars.allSatisfy({ scalar in
            scalar == ":" || ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
        }) else { return nil }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        guard Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// 이 기기에 tailnet 주소를 가진 네트워크 인터페이스가 있는지 봅니다.
    /// Tailscale이 꺼져 있으면 없습니다. macOS와 iOS에서 같은 방법을 씁니다.
    public static func hasLocalInterface() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var found = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor, !found {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // IPv6 주소 뒤의 `%utun0` 같은 구역 이름은 뗍니다.
            let text = String(cString: buffer).split(separator: "%").first.map(String.init) ?? ""
            found = isTailnetAddress(text)
        }
        return found
    }
}

/// `mdr://<host>:<port>/<token>/<path>` 링크가 가리키는 원격 문서입니다.
///
/// 링크는 믿을 수 없는 입력입니다(웹 페이지나 다른 문서에도 들어 있을 수 있습니다). 그래서 host가 tailnet
/// 주소일 때만 받고, 경로는 token이 가리키는 문서 폴더 밖으로 나가지 못하게 합니다.
public struct RemoteLocation: Hashable, Sendable {
    public static let scheme = "mdr"

    /// tailnet 범위의 IP 글자(IPv6이면 대괄호 없이)
    public let host: String
    public let port: Int
    public let token: String
    /// 문서 폴더 기준 경로의 조각들(디코딩된 글자). 비어 있지 않습니다.
    public let components: [String]

    public enum LinkError: Error, Equatable {
        case notMdrLink
        case hostNotAllowed(String)
        case malformed
    }

    /// 원래의 `mdr://` 링크
    public let url: URL
    /// 파일 내용을 받는 주소
    public let fileURL: URL
    /// 변경 알림(SSE)을 받는 주소
    public let eventsURL: URL

    public init(host: String, port: Int, token: String, components: [String]) throws {
        guard let address = Tailnet.canonicalAddress(host) else { throw LinkError.hostNotAllowed(host) }
        guard (1...65535).contains(port), Self.isValidToken(token),
              !components.isEmpty, components.allSatisfy(Self.isValidComponent) else { throw LinkError.malformed }
        let authority = (address.contains(":") ? "[\(address)]" : address) + ":\(port)"
        let path = components.map { $0.addingPercentEncoding(withAllowedCharacters: Self.componentAllowed) ?? "" }
        guard !path.contains(""),
              let url = URL(string: "\(Self.scheme)://\(authority)/\(token)/\(path.joined(separator: "/"))"),
              let fileURL = URL(string: "http://\(authority)/v1/\(token)/files/\(path.joined(separator: "/"))"),
              let eventsURL = URL(string: "http://\(authority)/v1/\(token)/events/\(path.joined(separator: "/"))"),
              fileURL.host?.trimmingCharacters(in: ["[", "]"]) == address else { throw LinkError.malformed }
        self.host = address
        self.port = port
        self.token = token
        self.components = components
        self.url = url
        self.fileURL = fileURL
        self.eventsURL = eventsURL
    }

    public init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme else { throw LinkError.notMdrLink }
        // 사용자 정보(`user@`)나 질의·조각이 붙은 링크는 받지 않습니다.
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, let port = parts.port else { throw LinkError.malformed }
        // 조각마다 따로 디코딩합니다. 디코딩한 조각에 `/`가 있으면(`%2F`) 거절합니다.
        let raw = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var decoded: [String] = []
        for piece in raw {
            guard let text = String(piece).removingPercentEncoding else { throw LinkError.malformed }
            decoded.append(text)
        }
        guard let token = decoded.first else { throw LinkError.malformed }
        try self.init(host: host, port: port, token: token, components: Array(decoded.dropFirst()))
    }

    private static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 128 && token.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
    }

    public var path: String { components.joined(separator: "/") }

    public var fileName: String { components.last ?? "" }

    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// 이 문서 안에 적힌 상대 경로(이미지, 다른 문서)가 가리키는 곳입니다.
    ///
    /// 같은 서버, 같은 token의 문서 폴더 안으로만 풀립니다. scheme이 있거나, `/`로 시작하거나,
    /// `..`으로 문서 폴더 밖을 가리키면 nil입니다. `#조각`과 `?질의`는 떼어 냅니다.
    public func resolving(_ reference: String) -> RemoteLocation? {
        var text = reference.trimmingCharacters(in: .whitespaces)
        if let cut = text.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            text = String(text[..<cut])
        }
        guard !text.isEmpty, !text.hasPrefix("/"), !text.hasPrefix("\\") else { return nil }
        // `scheme:`으로 시작하면 상대 경로가 아닙니다.
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") { return nil }
        var result = Array(components.dropLast())
        for piece in text.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(piece).removingPercentEncoding else { return nil }
            switch decoded {
            case ".": continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default:
                result.append(decoded)
            }
        }
        return try? RemoteLocation(host: host, port: port, token: token, components: result)
    }

    /// 같은 서버의 같은 문서 폴더를 가리키는지
    public func sharesRoot(with other: RemoteLocation) -> Bool {
        host == other.host && port == other.port && token == other.token
    }
}
