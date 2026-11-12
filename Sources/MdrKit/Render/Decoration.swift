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
        var full = CGRect(x: -frame.minX, y: 0, width: max(containerWidth, frame.maxX), height: frame.height)
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
        if paragraph.attribute(.attachment, at: 0, effectiveRange: nil) is BlockAttachment {
            return
        }
        super.draw(at: point, in: context)
    }

    private func drawDecorations(_ paragraph: NSAttributedString, at point: CGPoint, in context: CGContext) {
        let lines = textLineFragments
        guard let firstLine = lines.first, let lastLine = lines.last else { return }
        let containerX = point.x - layoutFragmentFrame.minX

        if let decoration = paragraph.attribute(.mdrDecoration, at: 0, effectiveRange: nil) as? BlockDecoration {
            if !decoration.quoteBars.isEmpty {
                let top = decoration.startsQuote ? firstLine.typographicBounds.minY : 0
                let bottom = decoration.endsQuote ? lastLine.typographicBounds.maxY : layoutFragmentFrame.height
                context.setFillColor(decoration.quoteBarColor.cgColor)
                for x in decoration.quoteBars {
                    let rect = CGRect(x: containerX + x, y: point.y + top, width: decoration.quoteBarWidth, height: bottom - top)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: decoration.quoteBarWidth / 2,
                                           cornerHeight: decoration.quoteBarWidth / 2, transform: nil))
                    context.fillPath()
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

/// `NSTextLayoutManager.delegate`로 지정하면 모든 문단을 `DecoratedLayoutFragment`로 그립니다.
public final class DecorationLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
