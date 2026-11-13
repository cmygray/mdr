import Foundation

/// 파서가 만들고 렌더러가 읽는 문서 모델입니다. 플랫폼 타입에 의존하지 않습니다.
public struct MarkdownDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter?
    public var blocks: [Block]

    public init(frontMatter: FrontMatter? = nil, blocks: [Block]) {
        self.frontMatter = frontMatter
        self.blocks = blocks
    }
}

/// 문서 맨 앞의 YAML front matter에서 읽기에 필요한 값만 꺼낸 것입니다.
public struct FrontMatter: Equatable, Sendable {
    public var title: String?
    public var source: String?
    public var raw: String

    public init(title: String? = nil, source: String? = nil, raw: String) {
        self.title = title
        self.source = source
        self.raw = raw
    }
}

public indirect enum Block: Equatable, Sendable {
    case heading(level: Int, content: [Inline])
    case paragraph([Inline])
    case blockQuote([Block])
    case list(ListBlock)
    case codeBlock(language: String?, code: String)
    case table(Table)
    /// 이미지 하나만 있는 문단입니다. 본문 폭에 맞춰 블록으로 그립니다.
    case image(ImageRef)
    case thematicBreak
    case htmlBlock(String)
    case footnoteDefinition(label: String, content: [Inline])
}

public struct ListBlock: Equatable, Sendable {
    public var ordered: Bool
    public var start: Int
    public var items: [ListItem]

    public init(ordered: Bool, start: Int = 1, items: [ListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct ListItem: Equatable, Sendable {
    public enum Checkbox: Equatable, Sendable { case checked, unchecked }
    public var checkbox: Checkbox?
    public var blocks: [Block]

    public init(checkbox: Checkbox? = nil, blocks: [Block]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct Table: Equatable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }
    public var alignments: [Alignment]
    public var header: [[Inline]]
    public var rows: [[[Inline]]]

    public init(alignments: [Alignment], header: [[Inline]], rows: [[[Inline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }
}

public struct ImageRef: Equatable, Sendable {
    public var source: String
    public var alt: String
    public var title: String?

    public init(source: String, alt: String, title: String? = nil) {
        self.source = source
        self.alt = alt
        self.title = title
    }
}

public indirect enum Inline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case link(destination: String, children: [Inline])
    case image(ImageRef)
    case superscript([Inline])
    case `subscript`([Inline])
    case footnoteReference(String)
    case softBreak
    case lineBreak
}

public extension Array where Element == Inline {
    /// 서식을 뺀 글자만 돌려줍니다. 목차 제목과 문자 통계에 씁니다.
    var plainText: String {
        var out = ""
        for inline in self {
            switch inline {
            case .text(let s), .code(let s): out += s
            case .emphasis(let c), .strong(let c), .strikethrough(let c),
                 .superscript(let c), .subscript(let c):
                out += c.plainText
            case .link(_, let c): out += c.plainText
            case .image(let ref): out += ref.alt
            case .footnoteReference: break
            case .softBreak, .lineBreak: out += " "
            }
        }
        return out
    }
}
