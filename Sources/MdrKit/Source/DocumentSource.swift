import Foundation

/// 문서가 어디에서 오는지입니다. 로컬 파일이거나, `mdr serve`가 내주는 원격 문서입니다.
public enum DocumentSource: Hashable, Sendable {
    case file(URL)
    case remote(RemoteLocation)

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func isMarkdown(fileName: String) -> Bool {
        markdownExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// 창 제목에 쓰는 파일 이름
    public var displayName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .remote(let location): return location.fileName
        }
    }

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// 문서 안의 링크를 눌렀을 때 할 일입니다.
public enum LinkAction: Equatable {
    /// 문서 안의 제목이나 각주로 이동
    case anchor(String)
    /// 웹 브라우저나 메일 앱으로 넘김
    case openExternally(URL)
    /// 이 앱에서 다른 문서를 엶
    case openDocument(DocumentSource)
    /// 실행하지 않고 파일 탐색기에서 보여 주기만 함
    case reveal(URL)
    /// 열지 않음
    case deny
}

/// 문서 안의 링크를 어떻게 다룰지 정합니다.
///
/// 문서 내용은 믿을 수 없는 입력입니다. 그래서 허용하는 것만 적어 두고 나머지는 열지 않습니다.
///
/// - 어느 문서에서든: `http`, `https`, `mailto`만 바깥 앱으로 넘깁니다.
/// - 로컬 문서: 로컬 마크다운은 이 앱으로 열고, 그 밖의 로컬 파일은 보여 주기만 합니다.
/// - 원격 문서: 같은 서버의 같은 문서 폴더에 있는 마크다운만 엽니다. 로컬 파일(`file:`)은 건드리지 않고,
///   다른 서버나 다른 token을 가리키는 `mdr:` 링크도 열지 않습니다.
public enum LinkPolicy {
    public static func action(for link: URL, in source: DocumentSource?) -> LinkAction {
        let scheme = link.scheme?.lowercased()
        if scheme == DocumentRenderer.anchorScheme {
            return .anchor(link.path)
        }
        switch scheme {
        case "http", "https", "mailto":
            return .openExternally(link)
        case "file":
            guard case .file = source else { return .deny }
            return DocumentSource.isMarkdown(fileName: link.lastPathComponent) ? .openDocument(.file(link)) : .reveal(link)
        case RemoteLocation.scheme:
            guard case .remote(let current) = source, let target = try? RemoteLocation(url: link),
                  target.sharesRoot(with: current), DocumentSource.isMarkdown(fileName: target.fileName) else { return .deny }
            return .openDocument(.remote(target))
        default:
            return .deny
        }
    }

    /// 문서에 적힌 링크 대상을 `.link` 속성에 넣을 값으로 바꿉니다. 누를 때 `action(for:in:)`이 다시 판단합니다.
    public static func linkValue(for destination: String, in source: DocumentSource?) -> Any {
        if destination.hasPrefix("#") {
            let fragment = String(destination.dropFirst()).removingPercentEncoding ?? String(destination.dropFirst())
            var components = URLComponents()
            components.scheme = DocumentRenderer.anchorScheme
            components.path = fragment
            return components.url ?? destination
        }
        if let url = URL(string: destination), url.scheme != nil {
            return url
        }
        switch source {
        case .file(let base):
            if let url = URL(string: destination, relativeTo: base) ?? LocalImageProvider.fileURL(for: destination, relativeTo: base) {
                return url.absoluteURL
            }
        case .remote(let location):
            if let target = location.resolving(destination) {
                return target.url
            }
        case nil:
            break
        }
        // 풀 수 없는 대상은 글자 그대로 둡니다. scheme이 없으므로 눌러도 열리지 않습니다.
        return destination
    }
}
