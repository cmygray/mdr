import Foundation

/// 조판을 정하는 데이터입니다. 렌더러는 이 값만 읽고, 값의 출처는 JSON 파일입니다.
///
/// 단위 규칙
/// - `size`, `step`: 본문 글자 크기에 대한 비율(또는 modular scale의 단계)
/// - `lineHeight`: 해당 요소 글자 크기에 대한 배수
/// - `spacing`, `spaceBefore`, `spaceAfter`, `indent`, `measure` 등 거리: 본문 글자 크기(em) 배수
/// - `padding*`, `cornerRadius`, `*Width`, `thickness`, `pageMargin`: pt
public struct StyleTokens: Codable, Equatable, Sendable {
    public var fonts: Fonts
    public var baseSize: Double
    public var scale: Double
    public var measure: ScriptValue
    public var pageMargin: Double
    public var pagePaddingY: Double
    public var body: Body
    public var headings: [Heading]
    public var link: Link
    public var inlineCode: InlineCode
    public var codeBlock: CodeBlock
    public var blockQuote: BlockQuote
    public var list: List
    public var table: Table
    public var image: Image
    public var rule: Rule
    public var footnote: Footnote
    public var colors: ColorSchemes

    public struct Fonts: Codable, Equatable, Sendable {
        public var body: FontSpec
        public var heading: FontSpec
        public var mono: FontSpec
    }

    /// `family`는 글꼴 가족 이름이거나 `system`, `system-serif`, `system-rounded`, `system-mono`입니다.
    /// `fallbacks`는 `family`에 없는 글자를 찾을 글꼴 순서입니다(한글·라틴 짝을 여기서 정합니다).
    public struct FontSpec: Codable, Equatable, Sendable {
        public var family: String
        public var fallbacks: [String]
    }

    /// 문서의 주 문자(한글·라틴)에 따라 달라지는 값입니다. 숫자 하나만 쓰면 둘에 같이 적용합니다.
    public struct ScriptValue: Codable, Equatable, Sendable {
        public var hangul: Double
        public var latin: Double

        public init(hangul: Double, latin: Double) {
            self.hangul = hangul
            self.latin = latin
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(Double.self) {
                hangul = single
                latin = single
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hangul = try container.decode(Double.self, forKey: .hangul)
            latin = try container.decode(Double.self, forKey: .latin)
        }

        public func value(for script: Script) -> Double {
            script == .hangul ? hangul : latin
        }
    }

    public struct Body: Codable, Equatable, Sendable {
        public var weight: Double
        public var strongWeight: Double
        public var lineHeight: ScriptValue
        public var paragraphSpacing: Double
        public var tracking: Double
        /// `hangulWord`(어절 단위) 또는 `standard`
        public var lineBreak: String
    }

    public struct Heading: Codable, Equatable, Sendable {
        public var step: Double
        public var weight: Double
        public var lineHeight: Double
        public var spaceBefore: Double
        public var spaceAfter: Double
        public var tracking: Double
        public var color: String
    }

    public struct Link: Codable, Equatable, Sendable {
        public var underline: Bool
    }

    public struct InlineCode: Codable, Equatable, Sendable {
        public var size: Double
        public var paddingX: Double
        public var paddingY: Double
        public var cornerRadius: Double
    }

    public struct CodeBlock: Codable, Equatable, Sendable {
        public var size: Double
        public var lineHeight: Double
        public var paddingX: Double
        public var paddingY: Double
        public var cornerRadius: Double
        public var borderWidth: Double
        public var spacing: Double
    }

    public struct BlockQuote: Codable, Equatable, Sendable {
        public var indent: Double
        public var barWidth: Double
        public var spacing: Double
    }

    public struct List: Codable, Equatable, Sendable {
        public var indent: Double
        public var markerGap: Double
        public var itemSpacing: Double
        public var bullets: [String]
    }

    public struct Table: Codable, Equatable, Sendable {
        public var size: Double
        public var lineHeight: Double
        public var headerWeight: Double
        public var cellPaddingX: Double
        public var cellPaddingY: Double
        public var minColumnWidth: Double
        public var maxColumnWidth: Double
        /// 표가 본문 폭에 들어가지 않을 때, 본문 폭의 몇 배까지 넓혀 가로 스크롤할지 정합니다.
        public var overflowFactor: Double
        public var borderWidth: Double
        public var cornerRadius: Double
        public var spacing: Double
    }

    public struct Image: Codable, Equatable, Sendable {
        public var spacing: Double
    }

    public struct Rule: Codable, Equatable, Sendable {
        public var thickness: Double
        public var spacing: Double
    }

    public struct Footnote: Codable, Equatable, Sendable {
        public var size: Double
        public var lineHeight: Double
        public var spacing: Double
    }

    public struct ColorSchemes: Codable, Equatable, Sendable {
        public var light: Colors
        public var dark: Colors
    }

    /// 색은 `#RRGGBB` 또는 `#RRGGBBAA`입니다.
    public struct Colors: Codable, Equatable, Sendable {
        public var background: String
        public var text: String
        public var heading: String
        public var secondaryText: String
        public var link: String
        public var codeText: String
        public var codeBackground: String
        public var inlineCodeBackground: String
        public var border: String
        public var quoteBar: String
        public var tableHeaderBackground: String
        public var marker: String

        func hex(named name: String) -> String {
            switch name {
            case "background": return background
            case "text": return text
            case "heading": return heading
            case "secondaryText": return secondaryText
            case "link": return link
            case "codeText": return codeText
            case "codeBackground": return codeBackground
            case "inlineCodeBackground": return inlineCodeBackground
            case "border": return border
            case "quoteBar": return quoteBar
            case "tableHeaderBackground": return tableHeaderBackground
            case "marker": return marker
            default: return name.hasPrefix("#") ? name : text
            }
        }
    }
}

public enum Script: String, Sendable {
    case hangul, latin

    /// 한글 음절이 글자의 일정 비율을 넘으면 한글 문서로 봅니다.
    /// 큰 문서도 빨리 끝나도록 UTF-8 바이트를 앞에서부터 일정량만 봅니다.
    public static func detect(in text: String) -> Script {
        var hangul = 0
        var latin = 0
        var seen = 0
        for byte in text.utf8 {
            seen += 1
            if seen > 262_144 { break }
            switch byte {
            // 한글 음절(U+AC00~U+D7A3)의 첫 바이트는 0xEA~0xED입니다.
            case 0xEA...0xED: hangul += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        guard hangul + latin > 0 else { return .latin }
        return Double(hangul) / Double(hangul + latin) >= 0.15 ? .hangul : .latin
    }
}

public enum ColorScheme: String, Sendable {
    case light, dark
}

// MARK: - Loading

public enum StyleTokensError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .unreadable(let message): return "토큰 파일을 읽을 수 없습니다: \(message)"
        case .invalid(let message): return "토큰 파일 형식이 잘못됐습니다: \(message)"
        }
    }
}

public extension StyleTokens {
    /// Package에 들어 있는 기본 토큰 파일의 위치입니다.
    static var bundledURL: URL {
        Bundle.module.url(forResource: "tokens", withExtension: "json")!
    }

    static let bundled: StyleTokens = {
        do {
            return try decodeStrict(Data(contentsOf: bundledURL))
        } catch {
            fatalError("번들된 tokens.json이 잘못됐습니다: \(error)")
        }
    }()

    /// 파일에서 읽습니다. 파일에 없는 키는 번들된 기본값으로 채웁니다.
    static func load(from url: URL) throws -> StyleTokens {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StyleTokensError.unreadable(error.localizedDescription)
        }
        return try load(from: data)
    }

    static func load(from data: Data) throws -> StyleTokens {
        do {
            let overrides = try JSONSerialization.jsonObject(with: data)
            let defaults = try JSONSerialization.jsonObject(with: Data(contentsOf: bundledURL))
            let merged = merge(defaults, overrides)
            return try decodeStrict(JSONSerialization.data(withJSONObject: merged))
        } catch let error as DecodingError {
            throw StyleTokensError.invalid(describe(error))
        } catch {
            throw StyleTokensError.invalid(error.localizedDescription)
        }
    }

    private static func decodeStrict(_ data: Data) throws -> StyleTokens {
        try JSONDecoder().decode(StyleTokens.self, from: data)
    }

    private static func merge(_ base: Any, _ overrides: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overrideDict = overrides as? [String: Any] else {
            return overrides
        }
        var out = baseDict
        for (key, value) in overrideDict {
            out[key] = baseDict[key].map { merge($0, value) } ?? value
        }
        return out
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context)).\(key.stringValue) 키가 없습니다"
        @unknown default:
            return "\(error)"
        }
    }
}
