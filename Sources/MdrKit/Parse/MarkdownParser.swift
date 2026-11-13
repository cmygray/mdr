import Foundation
import Markdown

/// 마크다운 원문을 `MarkdownDocument`로 바꿉니다.
///
/// swift-markdown(cmark-gfm)이 다루지 않는 세 가지를 여기서 보완합니다.
/// - YAML front matter: 잘라내고 제목과 출처만 꺼냅니다.
/// - 각주(`[^1]`, `[^1]: ...`): 참조와 정의를 모델로 올립니다.
/// - 인라인 HTML: `<sup>`, `<sub>`, `<br>`만 의미를 살리고 나머지 태그는 버립니다.
public enum MarkdownParser {
    public static func parse(_ source: String) -> MarkdownDocument {
        let (frontMatter, body) = splitFrontMatter(source)
        let prepared = escapeFootnoteDefinitions(body)
        let document = Markdown.Document(parsing: prepared)
        var converter = Converter(source: prepared)
        let blocks = converter.blocks(from: document.children)
        return MarkdownDocument(frontMatter: frontMatter, blocks: blocks)
    }

    // MARK: Front matter

    static func splitFrontMatter(_ source: String) -> (FrontMatter?, String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return (nil, source) }
        var lines: [Substring] = []
        var consumed = source.startIndex
        var closed = false
        var first = true
        var index = source.startIndex
        while index < source.endIndex {
            let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
            var line = source[index..<lineEnd]
            if line.hasSuffix("\r") { line = line.dropLast() }
            let next = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
            if first {
                first = false
            } else if line == "---" || line == "..." {
                consumed = next
                closed = true
                break
            } else {
                lines.append(line)
            }
            index = next
        }
        guard closed else { return (nil, source) }

        let raw = lines.joined(separator: "\n")
        var matter = FrontMatter(raw: raw)
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }
            switch key {
            case "title": matter.title = value
            case "source", "url": matter.source = value
            default: break
            }
        }
        return (matter, String(source[consumed...]))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        var inner = String(value.dropFirst().dropLast())
        if first == "\"" {
            inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return inner
    }

    // MARK: Footnotes

    /// 줄 맨 앞의 `[^label]:`를 `\[^label]:`로 바꿉니다. 그대로 두면 cmark가
    /// 내용이 한 단어인 각주 정의를 링크 참조 정의로 읽어 문서에서 지워 버립니다.
    /// 큰 문서에서도 빠르도록 UTF-8 바이트로 줄을 훑습니다.
    static func escapeFootnoteDefinitions(_ source: String) -> String {
        guard source.contains("[^") else { return source }
        let bytes = Array(source.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 64)
        var fence: (byte: UInt8, count: Int)?
        var lineStart = 0

        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let next = min(lineEnd + 1, bytes.count)

            var content = lineStart
            while content < lineEnd, bytes[content] == 0x20 { content += 1 }
            let indent = content - lineStart
            var escape = false

            if indent <= 3, content < lineEnd {
                let first = bytes[content]
                if first == 0x60 || first == 0x7E {
                    var run = content
                    while run < lineEnd, bytes[run] == first { run += 1 }
                    let count = run - content
                    if count >= 3 {
                        if let open = fence {
                            // 닫는 울타리는 여는 것과 같은 글자로 같은 길이 이상이고, 뒤에 공백만 옵니다.
                            var rest = run
                            while rest < lineEnd, bytes[rest] == 0x20 || bytes[rest] == 0x09 || bytes[rest] == 0x0D { rest += 1 }
                            if open.byte == first, count >= open.count, rest == lineEnd { fence = nil }
                        } else {
                            fence = (first, count)
                        }
                    }
                } else if fence == nil, first == 0x5B, content + 1 < lineEnd, bytes[content + 1] == 0x5E {
                    var close = content + 2
                    while close < lineEnd, bytes[close] != 0x5D { close += 1 }
                    escape = close + 1 < lineEnd && bytes[close + 1] == 0x3A
                }
            }

            if escape {
                out.append(contentsOf: bytes[lineStart..<content])
                out.append(0x5C)
                out.append(contentsOf: bytes[content..<next])
            } else {
                out.append(contentsOf: bytes[lineStart..<next])
            }
            lineStart = next
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - swift-markdown tree → model

private struct Converter {
    /// 원문 각 줄이 시작하는 위치입니다. `~` 하나짜리 취소선을 가려낼 때만 씁니다.
    private let source: String
    private let lineStarts: [String.UTF8View.Index]

    init(source: String) {
        self.source = source
        var starts: [String.UTF8View.Index] = []
        if source.utf8.contains(0x7E) {
            let utf8 = source.utf8
            starts.append(utf8.startIndex)
            var index = utf8.startIndex
            while index < utf8.endIndex {
                let next = utf8.index(after: index)
                if utf8[index] == 0x0A { starts.append(next) }
                index = next
            }
        }
        lineStarts = starts
    }

    /// cmark-gfm은 `~글자~`도 취소선으로 읽습니다. 한국어 문서는 `1~5`, `35~45자`처럼
    /// 물결표를 범위로 자주 쓰므로, `~~글자~~`만 취소선으로 인정합니다.
    private func usesDoubleTilde(_ node: Markdown.Strikethrough) -> Bool {
        guard let start = node.range?.lowerBound, start.line >= 1, start.line <= lineStarts.count else { return true }
        let utf8 = source.utf8
        guard let first = utf8.index(lineStarts[start.line - 1], offsetBy: start.column - 1, limitedBy: utf8.endIndex),
              first < utf8.endIndex else { return true }
        let second = utf8.index(after: first)
        return second < utf8.endIndex && utf8[first] == 0x7E && utf8[second] == 0x7E
    }

    mutating func blocks(from children: MarkupChildren) -> [Block] {
        var out: [Block] = []
        for child in children {
            if let block = block(from: child) {
                out.append(block)
            }
        }
        return out
    }

    private mutating func block(from markup: Markup) -> Block? {
        switch markup {
        case let heading as Markdown.Heading:
            return .heading(level: heading.level, content: inlines(from: heading.children))
        case let paragraph as Markdown.Paragraph:
            return paragraphBlock(inlines(from: paragraph.children))
        case let quote as Markdown.BlockQuote:
            return .blockQuote(blocks(from: quote.children))
        case let list as Markdown.UnorderedList:
            return .list(ListBlock(ordered: false, items: items(from: list.children)))
        case let list as Markdown.OrderedList:
            return .list(ListBlock(ordered: true, start: Int(list.startIndex), items: items(from: list.children)))
        case let code as Markdown.CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return .codeBlock(language: (language?.isEmpty ?? true) ? nil : language, code: text)
        case let html as Markdown.HTMLBlock:
            return .htmlBlock(html.rawHTML)
        case is Markdown.ThematicBreak:
            return .thematicBreak
        case let table as Markdown.Table:
            return .table(convert(table))
        default:
            // 알 수 없는 블록은 글자만 살립니다.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph([.text(text)])
        }
    }

    private func paragraphBlock(_ content: [Inline]) -> Block {
        // 이미지 하나만 있는 문단은 블록 이미지로 올립니다.
        let meaningful = content.filter {
            if case .text(let s) = $0 { return !s.allSatisfy(\.isWhitespace) }
            if case .softBreak = $0 { return false }
            return true
        }
        if meaningful.count == 1, case .image(let ref) = meaningful[0] {
            return .image(ref)
        }
        // `\[^label]: 내용`으로 시작하면 각주 정의입니다.
        if case .text(let first)? = content.first, first.hasPrefix("[^"),
           let close = first.firstIndex(of: "]"),
           first[first.index(after: close)...].hasPrefix(":") {
            let label = String(first[first.index(first.startIndex, offsetBy: 2)..<close])
            let rest = first[first.index(close, offsetBy: 2)...].drop(while: { $0 == " " })
            var body = Array(content.dropFirst())
            if !rest.isEmpty { body.insert(.text(String(rest)), at: 0) }
            return .footnoteDefinition(label: label, content: body)
        }
        return .paragraph(content)
    }

    private mutating func items(from children: MarkupChildren) -> [MdrKit.ListItem] {
        children.compactMap { child -> MdrKit.ListItem? in
            guard let item = child as? Markdown.ListItem else { return nil }
            let checkbox: MdrKit.ListItem.Checkbox? = item.checkbox.map { $0 == .checked ? .checked : .unchecked }
            return MdrKit.ListItem(checkbox: checkbox, blocks: blocks(from: item.children))
        }
    }

    private mutating func convert(_ table: Markdown.Table) -> MdrKit.Table {
        let alignments: [MdrKit.Table.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center?: return .center
            case .right?: return .trailing
            default: return .leading
            }
        }
        func cells(_ row: MarkupChildren) -> [[Inline]] {
            row.compactMap { ($0 as? Markdown.Table.Cell).map { inlines(from: $0.children) } }
        }
        let header = cells(table.head.children)
        let rows = table.body.children.compactMap { ($0 as? Markdown.Table.Row).map { cells($0.children) } }
        return MdrKit.Table(alignments: alignments, header: header, rows: rows)
    }

    // MARK: Inlines

    private func inlines(from children: MarkupChildren) -> [Inline] {
        var raw: [RawInline] = []
        for child in children {
            raw.append(contentsOf: rawInlines(from: child))
        }
        return resolveFootnotes(mergeText(resolveHTML(raw)))
    }

    /// HTML 태그를 풀기 전의 중간 표현입니다.
    private enum RawInline {
        case inline(Inline)
        case open(String)
        case close(String)
    }

    private func rawInlines(from markup: Markup) -> [RawInline] {
        switch markup {
        case let text as Markdown.Text:
            return [.inline(.text(text.string))]
        case let code as Markdown.InlineCode:
            return [.inline(.code(code.code))]
        case let node as Markdown.Emphasis:
            return [.inline(.emphasis(inlines(from: node.children)))]
        case let node as Markdown.Strong:
            return [.inline(.strong(inlines(from: node.children)))]
        case let node as Markdown.Strikethrough:
            let children = inlines(from: node.children)
            guard usesDoubleTilde(node) else {
                return [.inline(.text("~"))] + children.map { .inline($0) } + [.inline(.text("~"))]
            }
            return [.inline(.strikethrough(children))]
        case let link as Markdown.Link:
            return [.inline(.link(destination: link.destination ?? "", children: inlines(from: link.children)))]
        case let image as Markdown.Image:
            return [.inline(.image(ImageRef(source: image.source ?? "", alt: image.plainText, title: image.title)))]
        case is Markdown.SoftBreak:
            return [.inline(.softBreak)]
        case is Markdown.LineBreak:
            return [.inline(.lineBreak)]
        case let html as Markdown.InlineHTML:
            return htmlTag(html.rawHTML)
        case let symbol as Markdown.SymbolLink:
            return [.inline(.code(symbol.destination ?? ""))]
        default:
            let nested = markup.children.flatMap { rawInlines(from: $0) }
            return nested
        }
    }

    private func htmlTag(_ raw: String) -> [RawInline] {
        let lower = raw.lowercased()
        guard lower.hasPrefix("<"), lower.hasSuffix(">") else { return [] }
        var name = lower.dropFirst().dropLast()
        let closing = name.hasPrefix("/")
        if closing { name = name.dropFirst() }
        let tag = String(name.prefix(while: { $0.isLetter || $0.isNumber }))
        switch tag {
        case "br":
            return [.inline(.lineBreak)]
        case "sup", "sub":
            return [closing ? .close(tag) : .open(tag)]
        default:
            return []
        }
    }

    private func resolveHTML(_ raw: [RawInline]) -> [Inline] {
        var index = 0
        func parse(until closing: String?) -> [Inline] {
            var out: [Inline] = []
            while index < raw.count {
                let item = raw[index]
                index += 1
                switch item {
                case .inline(let inline):
                    out.append(inline)
                case .open(let tag):
                    let inner = parse(until: tag)
                    out.append(tag == "sup" ? .superscript(inner) : .subscript(inner))
                case .close(let tag):
                    if tag == closing { return out }
                }
            }
            return out
        }
        return parse(until: nil)
    }

    private func mergeText(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        out.reserveCapacity(inlines.count)
        for inline in inlines {
            if case .text(let next) = inline, case .text(let previous)? = out.last {
                out[out.count - 1] = .text(previous + next)
            } else {
                out.append(inline)
            }
        }
        return out
    }

    private func resolveFootnotes(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for (position, inline) in inlines.enumerated() {
            guard case .text(let text) = inline, text.contains("[^") else {
                out.append(inline)
                continue
            }
            var rest = text[...]
            var pending = ""
            while let open = rest.range(of: "[^") {
                let afterOpen = rest[open.upperBound...]
                guard let close = afterOpen.firstIndex(of: "]"),
                      close > afterOpen.startIndex,
                      !afterOpen[..<close].contains(where: { $0.isWhitespace || $0 == "[" }) else {
                    pending += rest[..<open.upperBound]
                    rest = afterOpen
                    continue
                }
                let afterClose = afterOpen[afterOpen.index(after: close)...]
                // 문단 맨 앞의 `[^label]:`는 정의이므로 건드리지 않습니다.
                if position == 0, out.isEmpty, pending.isEmpty, open.lowerBound == text.startIndex, afterClose.hasPrefix(":") {
                    pending += rest[..<afterClose.startIndex]
                    rest = afterClose
                    continue
                }
                pending += rest[..<open.lowerBound]
                if !pending.isEmpty { out.append(.text(pending)); pending = "" }
                out.append(.footnoteReference(String(afterOpen[..<close])))
                rest = afterClose
            }
            pending += rest
            if !pending.isEmpty { out.append(.text(pending)) }
        }
        return out
    }
}
