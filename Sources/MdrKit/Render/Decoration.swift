import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

public extension NSAttributedString.Key {
    /// 문단 단위 장식(`BlockDecoration`). 인용문 막대와 가로줄을 그릴 때 씁니다.
    static let mdrDecoration = NSAttributedString.Key("mdr.decoration")
    /// 인라인 코드 배경(`InlineCodeDecoration`)
    static let mdrInlineCode = NSAttributedString.Key("mdr.inlineCode")
    /// 각주 참조의 라벨(`[^label]`). 렌더링 끝에 정의 글과 돌아올 자리를 잇는 데 씁니다.
    static let mdrFootnoteReference = NSAttributedString.Key("mdr.footnoteReference")
    /// 각주 참조에 붙인 정의 글. 앱이 호버 툴팁으로 보여 줍니다.
    static let mdrFootnoteText = NSAttributedString.Key("mdr.footnoteText")
}

/// 글자가 아닌, 문단에 붙는 그림 요소입니다. `DecoratedLayoutFragment`가 읽어서 그립니다.
public final class BlockDecoration: NSObject {
    /// 인용문 막대의 왼쪽 x(본문 왼쪽 끝 기준). 중첩 인용이면 여러 개입니다.
    public var quoteBars: [CGFloat] = []
    public var quoteBarWidth: CGFloat = 3
    public var quoteBarColor: PlatformColor = .gray
    /// 인용문의 첫 문단이면 막대를 첫 줄 위에서, 마지막 문단이면 마지막 줄 아래에서 끊습니다.
    public var startsQuote = false
    public var endsQuote = false

    public var isRule = false
    public var ruleThickness: CGFloat = 1
    public var ruleColor: PlatformColor = .gray
    public var ruleInset: CGFloat = 0
}

public final class InlineCodeDecoration: NSObject {
    public let background: PlatformColor
    public let cornerRadius: CGFloat
    public let paddingX: CGFloat
    public let paddingY: CGFloat
    public let font: PlatformFont

    public init(background: PlatformColor, cornerRadius: CGFloat, paddingX: CGFloat, paddingY: CGFloat, font: PlatformFont) {
        self.background = background
        self.cornerRadius = cornerRadius
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.font = font
    }
}

/// 글자를 그리기 전에 인용문 막대, 가로줄, 인라인 코드 배경을 그리는 layout fragment입니다.
public final class DecoratedLayoutFragment: NSTextLayoutFragment {
    private var paragraph: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    public override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        let frame = layoutFragmentFrame
        // 막대와 가로줄은 글자 영역 밖(문단 왼쪽, 본문 전체 폭)에 그립니다.
        // 높이에 1pt를 더해, 다음 문단으로 이어지는 막대의 경계에 틈이 보이지 않게 합니다.
        var full = CGRect(x: -frame.minX, y: 0, width: max(containerWidth, frame.maxX), height: frame.height + 1)
        // 본문 폭보다 넓은 표는 좌우 여백까지 그립니다. 그릴 영역을 그만큼 넓혀 두지 않으면 잘립니다.
        if let paragraph, paragraph.length > 0,
           let table = paragraph.attribute(.attachment, at: 0, effectiveRange: nil) as? TableAttachment,
           let layout = table.currentLayout {
            let outset = max(0, (layout.visibleWidth - layout.columnWidth) / 2).rounded(.up)
            full = full.insetBy(dx: -outset, dy: 0)
        }
        return base.union(full)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        guard let paragraph, paragraph.length > 0 else {
            super.draw(at: point, in: context)
            return
        }
        context.saveGState()
        drawDecorations(paragraph, at: point, in: context)
        context.restoreGState()
        // view로 그리는 블록은 글자 쪽에서 그릴 것이 없습니다. 그대로 그리게 두면 TextKit이
        // 내용 없는 첨부의 기본 문서 아이콘을 view 밑에 깝니다. (첨부에 이미지를 주면 아이콘은
        // 사라지지만 TextKit이 view provider를 아예 요청하지 않습니다.)
        if paragraph.length <= 2, paragraph.attribute(.attachment, at: 0, effectiveRange: nil) is BlockAttachment {
            return
        }
        super.draw(at: point, in: context)
    }

    private func drawDecorations(_ paragraph: NSAttributedString, at point: CGPoint, in context: CGContext) {
        // 문서 맨 끝 문단에는 내용 없는 줄이 하나 더 붙을 수 있습니다. 장식 계산에서는 뺍니다.
        var lines = textLineFragments
        while lines.count > 1, let last = lines.last, last.characterRange.length == 0 { lines.removeLast() }
        guard let firstLine = lines.first, let lastLine = lines.last else { return }
        let containerX = point.x - layoutFragmentFrame.minX

        if let decoration = paragraph.attribute(.mdrDecoration, at: 0, effectiveRange: nil) as? BlockDecoration {
            if !decoration.quoteBars.isEmpty {
                let top = decoration.startsQuote ? firstLine.typographicBounds.minY : 0
                let bottom = decoration.endsQuote ? lastLine.typographicBounds.maxY : layoutFragmentFrame.height + 1
                context.setFillColor(decoration.quoteBarColor.cgColor)
                // 문단마다 따로 그리므로 끝을 둥글리지 않습니다. 둥글리면 문단 사이에 홈이 생깁니다.
                for x in decoration.quoteBars {
                    context.fill(CGRect(x: containerX + x, y: point.y + top, width: decoration.quoteBarWidth, height: bottom - top))
                }
            }
            if decoration.isRule {
                let y = point.y + firstLine.typographicBounds.midY - decoration.ruleThickness / 2
                let rect = CGRect(x: containerX + decoration.ruleInset, y: y.rounded(),
                                  width: containerWidth - decoration.ruleInset, height: decoration.ruleThickness)
                context.setFillColor(decoration.ruleColor.cgColor)
                context.fill(rect)
            }
        }

        for line in lines {
            let lineRange = line.characterRange
            guard lineRange.length > 0 else { continue }
            let string = line.attributedString
            string.enumerateAttribute(.mdrInlineCode, in: lineRange, options: []) { value, range, _ in
                guard let code = value as? InlineCodeDecoration else { return }
                let startX = line.locationForCharacter(at: range.location).x
                let endX: CGFloat
                if NSMaxRange(range) >= NSMaxRange(lineRange) {
                    endX = line.typographicBounds.width
                } else {
                    endX = line.locationForCharacter(at: NSMaxRange(range)).x
                }
                guard endX > startX else { return }
                let shift = (string.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0
                let baseline = line.typographicBounds.minY + line.glyphOrigin.y - shift
                let rect = CGRect(
                    x: point.x + line.typographicBounds.minX + startX - code.paddingX,
                    y: point.y + baseline - code.font.ascender - code.paddingY,
                    width: endX - startX + code.paddingX * 2,
                    height: code.font.ascender - code.font.descender + code.paddingY * 2
                )
                context.setFillColor(code.background.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: code.cornerRadius, cornerHeight: code.cornerRadius, transform: nil))
                context.fillPath()
            }
        }
    }
}

/// `NSTextLayoutManager.delegate`로 지정하면 모든 문단을 `DecoratedLayoutFragment`로 그리고,
/// 한글 어절이 영문·숫자와 맞닿은 자리에서 끊기지 않게 합니다.
public final class DecorationLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    /// false이면 줄바꿈 자리를 고치지 않습니다(토큰 `body.lineBreak`가 `hangulWord`가 아닐 때).
    public var keepsWordsWithHangulTogether = true

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    /// `hangulWordPriority`는 한글과 한글 사이만 붙여 둡니다. "API는", "3단계", "제1저자"처럼
    /// 영문·숫자와 한글이 맞닿은 자리는 여전히 끊을 수 있어서 조사가 다음 줄 첫머리로 떨어집니다.
    /// 그런 자리의 줄바꿈을 거절해 어절을 통째로 다음 줄로 보냅니다.
    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        shouldBreakLineBefore location: NSTextLocation,
        hyphenating: Bool
    ) -> Bool {
        guard keepsWordsWithHangulTogether, !hyphenating,
              let storage = textLayoutManager.textContentManager as? NSTextContentStorage,
              let string = storage.textStorage?.string as NSString? else { return true }
        let index = storage.offset(from: storage.documentRange.location, to: location)
        guard index > 0, index < string.length else { return true }
        let before = string.character(at: index - 1)
        let after = string.character(at: index)
        if Self.isHangul(after), Self.attachesToHangul(before) { return false }
        if Self.isHangul(before), Self.isASCIIAlphanumeric(after) { return false }
        return true
    }

    private static func isHangul(_ unit: unichar) -> Bool {
        (0xAC00...0xD7A3).contains(unit) || (0x3131...0x318E).contains(unit)
    }

    private static func isASCIIAlphanumeric(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    /// 뒤따르는 한글(조사 등)과 한 어절을 이루는 글자입니다. 영문·숫자와 닫는 괄호·따옴표·퍼센트.
    private static func attachesToHangul(_ unit: unichar) -> Bool {
        if isASCIIAlphanumeric(unit) { return true }
        switch unit {
        case 0x29, 0x5D, 0x7D, 0x22, 0x27, 0x25, 0x201D, 0x2019: return true
        default: return false
        }
    }
}
