import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

public struct OutlineItem: Equatable, Sendable {
    public let level: Int
    public let title: String
    /// 제목 문단이 시작하는 위치(UTF-16 offset)
    public let location: Int
}

public struct RenderedDocument {
    public let text: NSAttributedString
    public let outline: [OutlineItem]
    /// `#slug`와 각주(`fn-1`)가 가리키는 위치(UTF-16 offset)
    public let anchors: [String: Int]
    public let title: String?
    /// 본문 view가 폭이 바뀔 때마다 갱신해 주는 배치 조건
    public let environment: BlockLayoutEnvironment
}

/// 블록 모델을 하나의 attributed string으로 조판합니다.
///
/// 블록 사이 간격은 CSS의 margin 겹침처럼 정합니다. 블록마다 위·아래 여백을 갖고,
/// 이웃한 두 블록 사이에는 둘 중 큰 값 하나만 둡니다. 그래서 토큰의 `spaceBefore`는
/// 화면에 보이는 "제목 위 간격" 그대로입니다.
public final class DocumentRenderer {
    public static let anchorScheme = "mdr-anchor"

    private let style: ResolvedStyle
    private let baseURL: URL?
    private let output = NSMutableAttributedString()
    private var outline: [OutlineItem] = []
    private var anchors: [String: Int] = [:]
    private var slugCounts: [String: Int] = [:]
    private let environment = BlockLayoutEnvironment()
    private var previousBottomMargin: CGFloat?
    private var lastDecoration: BlockDecoration?
    /// 지금 만들고 있는 문단의 스타일과 장식입니다. `attributes(for:)`가 글자 속성에 함께 넣습니다.
    private var currentParagraph: NSParagraphStyle?
    private var currentDecoration: BlockDecoration?
    private var paragraphCache: [ParagraphKey: NSParagraphStyle] = [:]
    private var attributeCache: [AttributeKey: [NSAttributedString.Key: Any]] = [:]
    private lazy var inlineCode = InlineCodeDecoration(
        background: style.palette.inlineCodeBackground,
        cornerRadius: CGFloat(style.tokens.inlineCode.cornerRadius),
        paddingX: (CGFloat(style.tokens.inlineCode.paddingX) * style.em).rounded(),
        paddingY: (CGFloat(style.tokens.inlineCode.paddingY) * style.em).rounded(),
        font: style.font(.mono, size: (style.em * CGFloat(style.tokens.inlineCode.size)).rounded(), weight: 400)
    )

    private lazy var checkboxFont = FontFactory.make(
        .init(family: "Apple Symbols", fallbacks: []), size: (style.em * 1.2).rounded(), weight: 400)

    public init(style: ResolvedStyle, baseURL: URL?) {
        self.style = style
        self.baseURL = baseURL
    }

    public func render(_ document: MarkdownDocument) -> RenderedDocument {
        var title: String?
        if let matter = document.frontMatter {
            title = matter.title
            renderFrontMatter(matter, hasTopHeading: document.blocks.contains {
                if case .heading(level: 1, _) = $0 { return true }
                return false
            })
        }
        render(document.blocks, in: Context(color: style.palette.text))
        // 마지막 줄바꿈은 문서 끝에 빈 줄을 하나 더 만듭니다.
        if output.length > 0, (output.string as NSString).character(at: output.length - 1) == 0x0A {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        if title == nil {
            title = outline.first?.title
        }
        return RenderedDocument(text: output, outline: outline, anchors: anchors, title: title, environment: environment)
    }

    // MARK: - Context

    /// 중첩(목록, 인용문) 안에서 문단에 물려주는 값입니다.
    private struct Context {
        var indent: CGFloat = 0
        var quoteBars: [CGFloat] = []
        var color: PlatformColor
        var listDepth = 0
        /// 이 문맥에서 문단 아래에 두는 여백
        var paragraphBottom: CGFloat?
    }

    /// 문단 안의 글자 서식입니다.
    private struct TextStyle {
        var role: FontRole = .body
        var size: CGFloat
        var weight: Double
        var italic = false
        var color: PlatformColor
        var tracking: Double = 0
        var strikethrough = false
        var link: Any?
        var underline = false
        /// 위 첨자·아래 첨자의 기준선 이동량
        var shift: CGFloat = 0
    }

    /// 같은 서식의 속성 사전을 다시 만들지 않기 위한 열쇠입니다(링크가 없는 글자에만 씁니다).
    private struct AttributeKey: Hashable {
        var role: FontRole
        var size: CGFloat
        var weight: Double
        var italic: Bool
        var color: ObjectIdentifier
        var tracking: Double
        var strikethrough: Bool
        var shift: CGFloat
        var paragraph: ObjectIdentifier?
    }

    /// 같은 모양의 문단 스타일을 하나만 만들어 나눠 쓰기 위한 열쇠입니다.
    private struct ParagraphKey: Hashable {
        var lineHeight: CGFloat
        var fixed: Bool
        var firstIndent: CGFloat
        var headIndent: CGFloat
        var before: CGFloat
        var after: CGFloat
        var markerEnd: CGFloat?
    }

    /// 목록 항목처럼 첫 줄에 표지를 내어 쓰는 문단의 들여쓰기입니다.
    private struct Hanging {
        var first: CGFloat
        var head: CGFloat
        /// 표지를 오른쪽 맞춤하는 위치
        var markerEnd: CGFloat
    }

    private var em: CGFloat { style.em }

    // MARK: - Blocks

    private func render(_ blocks: [Block], in context: Context) {
        for block in blocks {
            render(block, in: context)
        }
    }

    private func render(_ block: Block, in context: Context) {
        switch block {
        case .heading(let level, let content):
            renderHeading(level: level, content: content, in: context)
        case .paragraph(let content):
            renderParagraph(content, in: context)
        case .blockQuote(let blocks):
            renderBlockQuote(blocks, in: context)
        case .list(let list):
            renderList(list, in: context)
        case .codeBlock(let language, let code):
            renderCodeBlock(code, language: language, in: context)
        case .table(let table):
            renderTable(table, in: context)
        case .image(let ref):
            renderImageBlock(ref, in: context)
        case .thematicBreak:
            renderRule(in: context)
        case .htmlBlock(let html):
            renderHTMLBlock(html, in: context)
        case .footnoteDefinition(let label, let content):
            renderFootnote(label: label, content: content, in: context)
        }
    }

    private func renderFrontMatter(_ matter: FrontMatter, hasTopHeading: Bool) {
        let context = Context(color: style.palette.text)
        if let title = matter.title, !hasTopHeading {
            renderHeading(level: 1, content: [.text(title)], in: context)
        }
        if let source = matter.source {
            let size = (em * CGFloat(style.tokens.footnote.size)).rounded()
            let lineHeight = (size * CGFloat(style.tokens.footnote.lineHeight)).rounded()
            let text = TextStyle(size: size, weight: style.tokens.body.weight, color: style.palette.secondaryText)
            beginParagraph(top: 0, bottom: CGFloat(style.tokens.body.paragraphSpacing) * em, lineHeight: lineHeight,
                           font: style.font(.body, size: size, weight: text.weight), context: context)
            let line = NSMutableAttributedString()
            append([.link(destination: source, children: [.text(source)])], to: line, style: text)
            endParagraph(line)
        }
    }

    private func renderHeading(level: Int, content: [Inline], in context: Context) {
        let token = style.heading(level: level)
        let size = style.scaledSize(step: token.step)
        let lineHeight = (size * CGFloat(token.lineHeight)).rounded()
        let font = style.font(.heading, size: size, weight: token.weight)
        let text = TextStyle(role: .heading, size: size, weight: token.weight, color: style.color(named: token.color), tracking: token.tracking)

        let title = content.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = output.length
        outline.append(OutlineItem(level: level, title: title, location: location))
        let slug = uniqueSlug(for: title)
        anchors[slug] = location

        beginParagraph(top: CGFloat(token.spaceBefore) * em, bottom: CGFloat(token.spaceAfter) * em, lineHeight: lineHeight,
                       font: font, context: context)
        let line = NSMutableAttributedString()
        append(content, to: line, style: text)
        endParagraph(line)
    }

    private func bodyTextStyle(in context: Context) -> TextStyle {
        TextStyle(size: em, weight: style.tokens.body.weight, color: context.color, tracking: style.tokens.body.tracking)
    }

    private func paragraphBottom(in context: Context) -> CGFloat {
        context.paragraphBottom ?? CGFloat(style.tokens.body.paragraphSpacing) * em
    }

    /// `marker`를 주면 목록 항목으로 그립니다. 표지는 `hanging.markerEnd`에 오른쪽 맞춤합니다.
    private func renderParagraph(_ content: [Inline], in context: Context, marker: String? = nil, hanging: Hanging? = nil) {
        let isCheckbox = marker == "☐" || marker == "☑"
        beginParagraph(top: 0, bottom: paragraphBottom(in: context), lineHeight: style.bodyLineHeight,
                       font: style.bodyFont, context: context, hanging: hanging)
        let line = NSMutableAttributedString()
        if let marker {
            var markerStyle = bodyTextStyle(in: context)
            markerStyle.color = style.palette.marker
            var markerAttributes = attributes(for: markerStyle)
            if isCheckbox {
                // 체크 상자 두 글자가 서로 다른 대체 글꼴에서 오면 크기가 달라 보입니다. 한 글꼴로 맞춥니다.
                markerAttributes[.font] = checkboxFont
            }
            line.append(NSAttributedString(string: "\t\(marker)\t", attributes: markerAttributes))
        }
        let hasImage = append(content, to: line, style: bodyTextStyle(in: context))
        endParagraph(line, releasesLineHeight: hasImage)
    }

    private func renderBlockQuote(_ blocks: [Block], in context: Context) {
        let token = style.tokens.blockQuote
        var inner = context
        inner.quoteBars.append(context.indent)
        inner.indent += (CGFloat(token.indent) * em).rounded()
        inner.color = style.palette.secondaryText
        inner.paragraphBottom = nil

        let spacing = CGFloat(token.spacing) * em
        raiseTopMargin(spacing)
        let outerLast = lastDecoration
        lastDecoration = nil
        let start = output.length
        render(blocks, in: inner)
        if output.length > start {
            (output.attribute(.mdrDecoration, at: start, effectiveRange: nil) as? BlockDecoration)?.startsQuote = true
            lastDecoration?.endsQuote = true
        } else {
            lastDecoration = outerLast
        }
        previousBottomMargin = max(spacing, paragraphBottom(in: context))
    }

    private func renderList(_ list: ListBlock, in context: Context) {
        let token = style.tokens.list
        let gap = (CGFloat(token.markerGap) * em).rounded()
        let itemSpacing = CGFloat(token.itemSpacing) * em
        let markerFont = style.bodyFont

        let markers: [String] = list.items.enumerated().map { index, item in
            switch item.checkbox {
            case .checked?: return "☑"
            case .unchecked?: return "☐"
            case nil:
                if list.ordered { return "\(list.start + index)." }
                return token.bullets.isEmpty ? "•" : token.bullets[min(context.listDepth, token.bullets.count - 1)]
            }
        }
        let widest = markers.map { ($0 as NSString).size(withAttributes: [.font: markerFont]).width }.max() ?? 0
        let column = max((CGFloat(token.indent) * em).rounded(), ceil(widest) + gap)

        var inner = context
        inner.indent += column
        inner.listDepth += 1
        inner.paragraphBottom = itemSpacing

        let hanging = Hanging(first: context.indent, head: inner.indent, markerEnd: inner.indent - gap)
        for (index, item) in list.items.enumerated() {
            var rest = item.blocks[...]
            if case .paragraph(let content)? = rest.first {
                renderParagraph(content, in: inner, marker: markers[index], hanging: hanging)
                rest = rest.dropFirst()
            } else {
                renderParagraph([], in: inner, marker: markers[index], hanging: hanging)
            }
            render(Array(rest), in: inner)
            previousBottomMargin = itemSpacing
        }
        previousBottomMargin = paragraphBottom(in: context)
    }

    private func renderCodeBlock(_ code: String, language: String?, in context: Context) {
        let token = style.tokens.codeBlock
        let size = (em * CGFloat(token.size) * 2).rounded() / 2
        let lineHeight = (size * CGFloat(token.lineHeight)).rounded()
        let font = style.font(.mono, size: size, weight: 400)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        paragraph.tabStops = []
        let attributed = NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: style.palette.codeText,
            .paragraphStyle: paragraph,
        ])
        let attachment = CodeBlockAttachment(code: code, language: language, attributedCode: attributed, style: .init(
            background: style.palette.codeBackground,
            borderColor: style.palette.border,
            borderWidth: CGFloat(token.borderWidth),
            cornerRadius: CGFloat(token.cornerRadius),
            paddingX: CGFloat(token.paddingX),
            paddingY: CGFloat(token.paddingY),
            lineHeight: lineHeight,
            halfLeading: style.halfLeading(for: font, lineHeight: lineHeight)
        ))
        emitAttachment(attachment, spacing: CGFloat(token.spacing) * em, context: context)
    }

    private func renderTable(_ table: Table, in context: Context) {
        let token = style.tokens.table
        let size = (em * CGFloat(token.size) * 2).rounded() / 2
        let lineHeight = (size * CGFloat(token.lineHeight)).rounded()
        let columns = table.columnCount

        func cell(_ content: [Inline], column: Int, header: Bool) -> NSAttributedString {
            let weight = header ? token.headerWeight : style.tokens.body.weight
            let text = TextStyle(size: size, weight: weight, color: header ? style.palette.heading : context.color)
            let alignment = column < table.alignments.count ? table.alignments[column] : .leading
            currentParagraph = cellParagraphs[alignment] ?? {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
                paragraph.lineBreakStrategy = style.lineBreakStrategy
                switch alignment {
                case .leading: paragraph.alignment = .natural
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }
                cellParagraphs[alignment] = paragraph
                return paragraph
            }()
            currentDecoration = nil
            let string = NSMutableAttributedString()
            append(content, to: string, style: text)
            return string
        }
        var cellParagraphs: [Table.Alignment: NSParagraphStyle] = [:]
        func row(_ cells: [[Inline]], header: Bool) -> [NSAttributedString] {
            (0..<columns).map { cell($0 < cells.count ? cells[$0] : [], column: $0, header: header) }
        }

        let rows = [row(table.header, header: true)] + table.rows.map { row($0, header: false) }
        let attachment = TableAttachment(rows: rows, style: .init(
            borderColor: style.palette.border,
            borderWidth: CGFloat(token.borderWidth),
            headerBackground: style.palette.tableHeaderBackground,
            cornerRadius: CGFloat(token.cornerRadius),
            cellPaddingX: CGFloat(token.cellPaddingX),
            cellPaddingY: CGFloat(token.cellPaddingY),
            minColumnWidth: CGFloat(token.minColumnWidth) * em,
            maxColumnWidth: CGFloat(token.maxColumnWidth) * em,
            overflowFactor: CGFloat(token.overflowFactor),
            halfLeading: style.halfLeading(for: style.font(.body, size: size, weight: style.tokens.body.weight), lineHeight: lineHeight)
        ), environment: context.indent == 0 ? environment : nil)
        emitAttachment(attachment, spacing: CGFloat(token.spacing) * em, context: context)
    }

    private func renderImageBlock(_ ref: ImageRef, in context: Context) {
        guard let attachment = imageAttachment(for: ref) else {
            renderParagraph([.image(ref)], in: context)
            return
        }
        emitAttachment(attachment, spacing: CGFloat(style.tokens.image.spacing) * em, context: context)
    }

    private func renderRule(in context: Context) {
        let token = style.tokens.rule
        let decoration = makeDecoration(in: context)
        decoration.isRule = true
        decoration.ruleThickness = CGFloat(token.thickness)
        decoration.ruleColor = style.palette.border
        decoration.ruleInset = context.indent
        beginParagraph(top: CGFloat(token.spacing) * em, bottom: CGFloat(token.spacing) * em,
                       lineHeight: max(CGFloat(token.thickness), 2), font: nil, fixedLineHeight: true,
                       context: context, decoration: decoration)
        var attributes = paragraphAttributes
        attributes[.font] = style.font(.body, size: 2, weight: 400)
        endParagraph(NSMutableAttributedString(string: "\u{00A0}", attributes: attributes))
    }

    private func renderHTMLBlock(_ html: String, in context: Context) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<!--") { return }
        var inner = context
        inner.color = style.palette.secondaryText
        if trimmed.range(of: "<svg", options: .caseInsensitive) != nil {
            renderParagraph([.omitted("SVG")], in: inner)
            return
        }
        // 그 밖의 HTML은 태그를 떼고 글자만 보여 줍니다.
        let text = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            renderParagraph([.text(text)], in: context)
        }
    }

    private func renderFootnote(label: String, content: [Inline], in context: Context) {
        let token = style.tokens.footnote
        let size = (em * CGFloat(token.size) * 2).rounded() / 2
        let lineHeight = (size * CGFloat(token.lineHeight)).rounded()
        let text = TextStyle(size: size, weight: style.tokens.body.weight, color: style.palette.secondaryText)

        anchors["fn-\(label)"] = output.length
        let marker = "\(label)."
        let font = style.font(.body, size: size, weight: text.weight)
        let gap = (CGFloat(style.tokens.list.markerGap) * em).rounded()
        let column = max((CGFloat(style.tokens.list.indent) * em).rounded(),
                         ceil((marker as NSString).size(withAttributes: [.font: font]).width) + gap)
        beginParagraph(top: 0, bottom: CGFloat(token.spacing) * em, lineHeight: lineHeight, font: font, context: context,
                       hanging: Hanging(first: context.indent, head: context.indent + column, markerEnd: context.indent + column - gap))
        var markerStyle = text
        markerStyle.color = style.palette.marker
        let line = NSMutableAttributedString(string: "\t\(marker)\t", attributes: attributes(for: markerStyle))
        append(content, to: line, style: text)
        endParagraph(line)
    }

    // MARK: - Emission

    private func makeDecoration(in context: Context) -> BlockDecoration {
        let decoration = BlockDecoration()
        decoration.quoteBars = context.quoteBars
        decoration.quoteBarWidth = CGFloat(style.tokens.blockQuote.barWidth)
        decoration.quoteBarColor = style.palette.quoteBar
        return decoration
    }

    /// 다음에 나올 블록의 위 여백이 적어도 `margin`이 되게 합니다.
    private func raiseTopMargin(_ margin: CGFloat) {
        if let previous = previousBottomMargin {
            previousBottomMargin = max(previous, margin)
        }
    }

    /// 문단을 시작합니다. `top`/`bottom`은 이 블록의 위·아래 여백(pt)입니다.
    /// `font`는 문단의 기준 글꼴입니다. 주면 줄 높이를 고정하고 글자를 줄 상자 가운데로 보정합니다.
    ///
    /// 문단 스타일을 글자를 붙이기 전에 정해 두고 글자 속성에 함께 넣습니다. 나중에 문단 전체에
    /// 덧입히면 글자 조각마다 속성 사전을 다시 만들어 큰 문서에서 느립니다.
    private func beginParagraph(
        top: CGFloat,
        bottom: CGFloat,
        lineHeight: CGFloat,
        font: PlatformFont?,
        fixedLineHeight: Bool? = nil,
        context: Context,
        decoration: BlockDecoration? = nil,
        hanging: Hanging? = nil
    ) {
        // 문서 맨 처음 블록 위에는 여백을 두지 않습니다(페이지 여백은 view가 줍니다).
        let gap = previousBottomMargin.map { max($0, top) } ?? 0
        let half = font.map { style.halfLeading(for: $0, lineHeight: lineHeight) } ?? 0
        previousBottomMargin = bottom

        let key = ParagraphKey(
            lineHeight: lineHeight,
            fixed: fixedLineHeight ?? (font != nil),
            firstIndent: hanging?.first ?? context.indent,
            headIndent: hanging?.head ?? context.indent,
            before: max(0, gap - half).rounded(),
            after: half.rounded(),
            markerEnd: hanging?.markerEnd
        )
        currentParagraph = paragraphStyle(for: key)
        currentDecoration = decoration ?? (context.quoteBars.isEmpty ? nil : makeDecoration(in: context))
        if let currentDecoration { lastDecoration = currentDecoration }
    }

    private func paragraphStyle(for key: ParagraphKey) -> NSParagraphStyle {
        if let cached = paragraphCache[key] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = key.lineHeight
        if key.fixed { paragraph.maximumLineHeight = key.lineHeight }
        paragraph.lineBreakStrategy = style.lineBreakStrategy
        paragraph.firstLineHeadIndent = key.firstIndent
        paragraph.headIndent = key.headIndent
        paragraph.paragraphSpacingBefore = key.before
        paragraph.paragraphSpacing = key.after
        if let markerEnd = key.markerEnd {
            paragraph.tabStops = [
                NSTextTab(textAlignment: .right, location: markerEnd),
                NSTextTab(textAlignment: .left, location: key.headIndent),
            ]
        }
        paragraphCache[key] = paragraph
        return paragraph
    }

    /// 문단 단위 속성(문단 스타일, 장식)입니다. 글자 서식 없이 붙이는 조각에 씁니다.
    private var paragraphAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let currentParagraph { attributes[.paragraphStyle] = currentParagraph }
        if let currentDecoration { attributes[.mdrDecoration] = currentDecoration }
        return attributes
    }

    /// 문단을 끝내고 출력에 붙입니다. `releasesLineHeight`이면 줄 높이 고정을 풉니다(글 안에 이미지가 있을 때).
    private func endParagraph(_ content: NSMutableAttributedString, releasesLineHeight: Bool = false) {
        var newline = content.length > 0 ? content.attributes(at: content.length - 1, effectiveRange: nil) : paragraphAttributes
        if newline[.font] == nil { newline[.font] = style.bodyFont }
        newline[.attachment] = nil
        newline[.link] = nil
        content.append(NSAttributedString(string: "\n", attributes: newline))
        if releasesLineHeight, let currentParagraph, let relaxed = currentParagraph.mutableCopy() as? NSMutableParagraphStyle {
            relaxed.maximumLineHeight = 0
            // 줄 높이를 고정하지 않으면 가운데 보정도 필요 없습니다.
            relaxed.paragraphSpacingBefore += relaxed.paragraphSpacing
            relaxed.paragraphSpacing = 0
            content.addAttribute(.paragraphStyle, value: relaxed, range: NSRange(location: 0, length: content.length))
        }
        output.append(content)
        currentParagraph = nil
        currentDecoration = nil
    }

    private func emitAttachment(_ attachment: NSTextAttachment, spacing: CGFloat, context: Context) {
        beginParagraph(top: spacing, bottom: max(spacing, paragraphBottom(in: context)), lineHeight: 1, font: nil, context: context)
        // 첨부 문자 줄의 높이는 첨부 크기가 정합니다. 글꼴이 줄 아래에 여분을 만들지 않게 아주 작게 둡니다.
        var attributes = paragraphAttributes
        attributes[.font] = style.font(.body, size: 1, weight: 400)
        let line = NSMutableAttributedString(attachment: attachment)
        line.addAttributes(attributes, range: NSRange(location: 0, length: line.length))
        endParagraph(line)
    }

    // MARK: - Inlines

    private func attributes(for text: TextStyle) -> [NSAttributedString.Key: Any] {
        // 링크와 장식이 없는 보통 글자는 문단 스타일까지 합친 사전을 통째로 재사용합니다.
        let cacheable = text.link == nil && currentDecoration == nil
        let key = AttributeKey(
            role: text.role, size: text.size, weight: text.weight, italic: text.italic,
            color: ObjectIdentifier(text.color), tracking: text.tracking, strikethrough: text.strikethrough,
            shift: text.shift, paragraph: currentParagraph.map(ObjectIdentifier.init)
        )
        if cacheable, let cached = attributeCache[key] { return cached }

        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: text.color]
        attributes[.font] = text.italic
            ? style.italicFont(text.role, size: text.size, weight: text.weight)
            : style.font(text.role, size: text.size, weight: text.weight)
        if text.shift != 0 { attributes[.baselineOffset] = text.shift }
        if text.tracking != 0 { attributes[.kern] = CGFloat(text.tracking) * text.size }
        if text.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = text.link {
            attributes[.link] = link
            attributes[.foregroundColor] = style.palette.link
            if style.tokens.link.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if let currentParagraph { attributes[.paragraphStyle] = currentParagraph }
        if let currentDecoration { attributes[.mdrDecoration] = currentDecoration }
        if cacheable { attributeCache[key] = attributes }
        return attributes
    }

    /// 인라인을 `target`에 붙입니다. 인라인 이미지를 넣었으면 true를 돌려줍니다.
    @discardableResult
    private func append(_ inlines: [Inline], to target: NSMutableAttributedString, style text: TextStyle) -> Bool {
        var hasImage = false
        for inline in inlines {
            switch inline {
            case .text(let string):
                target.append(NSAttributedString(string: string, attributes: attributes(for: text)))
            case .softBreak:
                target.append(NSAttributedString(string: " ", attributes: attributes(for: text)))
            case .lineBreak:
                target.append(NSAttributedString(string: "\u{2028}", attributes: attributes(for: text)))
            case .code(let code):
                appendInlineCode(code, to: target, style: text)
            case .emphasis(let children):
                var inner = text
                inner.italic = true
                hasImage = append(children, to: target, style: inner) || hasImage
            case .strong(let children):
                var inner = text
                inner.weight = max(text.weight, self.style.tokens.body.strongWeight)
                hasImage = append(children, to: target, style: inner) || hasImage
            case .strikethrough(let children):
                var inner = text
                inner.strikethrough = true
                hasImage = append(children, to: target, style: inner) || hasImage
            case .link(let destination, let children):
                var inner = text
                inner.link = linkValue(for: destination)
                hasImage = append(children, to: target, style: inner) || hasImage
            case .superscript(let children), .subscript(let children):
                var inner = text
                inner.size = (text.size * 0.75).rounded()
                if case .superscript = inline {
                    inner.shift = text.shift + text.size * 0.36
                } else {
                    inner.shift = text.shift - text.size * 0.12
                }
                hasImage = append(children, to: target, style: inner) || hasImage
            case .omitted(let kind):
                var inner = text
                inner.color = self.style.palette.secondaryText
                inner.italic = true
                target.append(NSAttributedString(string: "[\(kind) 그림은 표시하지 않습니다]", attributes: attributes(for: inner)))
            case .footnoteReference(let label):
                var inner = text
                inner.size = (text.size * 0.75).rounded()
                inner.shift = text.shift + text.size * 0.36
                inner.link = linkValue(for: "#fn-\(label)")
                target.append(NSAttributedString(string: label, attributes: attributes(for: inner)))
            case .image(let ref):
                if let attachment = imageAttachment(for: ref) {
                    let string = NSMutableAttributedString(attachment: attachment)
                    string.addAttributes(attributes(for: text), range: NSRange(location: 0, length: string.length))
                    target.append(string)
                    hasImage = true
                } else {
                    // 불러올 수 없는 이미지는 대체 글자로 보여 줍니다.
                    var inner = text
                    inner.color = self.style.palette.secondaryText
                    let label = ref.alt.isEmpty ? ref.source : ref.alt
                    target.append(NSAttributedString(string: "[이미지: \(label)]", attributes: attributes(for: inner)))
                }
            }
        }
        return hasImage
    }

    private func appendInlineCode(_ code: String, to target: NSMutableAttributedString, style text: TextStyle) {
        var inner = text
        inner.role = .mono
        inner.size = inlineCode.font.pointSize
        inner.weight = 400
        inner.italic = false
        inner.tracking = 0
        if text.link == nil { inner.color = self.style.palette.codeText }
        var attributes = attributes(for: inner)
        attributes[.mdrInlineCode] = inlineCode

        // 배경 상자가 앞뒤 글자에 붙지 않게, 상자의 좌우 여백만큼 자간을 벌립니다.
        let padding = inlineCode.paddingX
        if target.length > 0 {
            let last = target.length - 1
            let previous = (target.string as NSString).character(at: last)
            if previous != 0x0A, previous != 0x2028, previous != 0x09 {
                let kern = (target.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat) ?? 0
                target.addAttribute(.kern, value: kern + padding, range: NSRange(location: last, length: 1))
            }
        }
        let string = NSMutableAttributedString(string: code, attributes: attributes)
        if string.length > 0 {
            string.addAttribute(.kern, value: padding, range: NSRange(location: string.length - 1, length: 1))
        }
        target.append(string)
    }

    // MARK: - Links, images, anchors

    private func linkValue(for destination: String) -> Any {
        if destination.hasPrefix("#") {
            let fragment = String(destination.dropFirst()).removingPercentEncoding ?? String(destination.dropFirst())
            var components = URLComponents()
            components.scheme = Self.anchorScheme
            components.path = fragment
            return components.url ?? destination
        }
        if let url = URL(string: destination), url.scheme != nil {
            return url
        }
        if let baseURL, let url = URL(string: destination, relativeTo: baseURL) ?? fileURL(for: destination) {
            return url.absoluteURL
        }
        return destination
    }

    private func fileURL(for path: String) -> URL? {
        guard let baseURL else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
    }

    private func imageAttachment(for ref: ImageRef) -> ImageAttachment? {
        if let url = URL(string: ref.source), let scheme = url.scheme {
            return scheme == "file" ? ImageAttachment(url: url) : nil
        }
        guard let url = fileURL(for: ref.source) else { return nil }
        return ImageAttachment(url: url)
    }

    private func uniqueSlug(for title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "_" {
                slug.append(character)
            } else if character == " " || character == "-" {
                slug.append("-")
            }
        }
        let count = slugCounts[slug, default: 0]
        slugCounts[slug] = count + 1
        return count == 0 ? slug : "\(slug)-\(count)"
    }
}
