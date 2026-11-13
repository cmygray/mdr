import Foundation
import ImageIO

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// 본문 view가 블록에게 알려 주는 배치 조건입니다. 문서 하나의 모든 블록이 같은 객체를 봅니다.
public final class BlockLayoutEnvironment {
    /// 본문 폭을 넘는 블록(넓은 표)이 쓸 수 있는 최대 폭입니다. 0이면 본문 폭 안에만 그립니다.
    public var bleedWidth: CGFloat = 0

    public init() {}
}

/// view로 그리는 블록(코드 블록, 표)의 공통 부모입니다.
///
/// 크기는 여기(공유 코드)에서 계산하고, 실제 view는 플랫폼 앱이 `providerFactory`로 만들어 줍니다.
open class BlockAttachment: NSTextAttachment {
    public typealias ProviderFactory = (
        _ attachment: BlockAttachment,
        _ parentView: PlatformView?,
        _ textLayoutManager: NSTextLayoutManager?,
        _ location: NSTextLocation
    ) -> NSTextAttachmentViewProvider?

    /// 앱이 시작할 때 한 번 지정합니다.
    nonisolated(unsafe) public static var providerFactory: ProviderFactory?

    public init() {
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 쓸 수 있는 폭이 주어졌을 때 이 블록이 차지할 크기입니다.
    open func size(forAvailableWidth width: CGFloat) -> CGSize {
        .zero
    }

    public override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        // 기본 구현을 불러야 TextKit이 배치 단계에서 view provider를 만들어 문단에 등록합니다.
        // 부르지 않으면 provider는 글자를 그릴 때에야 만들어져, view가 다음 배치 회차까지 붙지 않습니다.
        _ = super.attachmentBounds(for: attributes, location: location, textContainer: textContainer,
                                   proposedLineFragment: proposedLineFragment, position: position)
        let available = max(proposedLineFragment.width - position.x, 40)
        return CGRect(origin: .zero, size: size(forAvailableWidth: available))
    }

    private var provider: NSTextAttachmentViewProvider?

    public override func viewProvider(
        for parentView: PlatformView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // 다시 배치할 때마다 view를 새로 만들지 않도록 provider를 재사용합니다.
        if provider == nil {
            guard let created = Self.providerFactory?(self, parentView, textContainer?.textLayoutManager, location) else {
                return nil
            }
            created.tracksTextAttachmentViewBounds = false
            // 이 메서드를 재정의하면 TextKit이 `loadView()`를 불러 주지 않습니다. 직접 부릅니다.
            created.loadView()
            provider = created
        }
        return provider
    }
}

// MARK: - Code block

public final class CodeBlockAttachment: BlockAttachment {
    public struct Style {
        public var background: PlatformColor
        public var borderColor: PlatformColor
        public var borderWidth: CGFloat
        public var cornerRadius: CGFloat
        public var paddingX: CGFloat
        public var paddingY: CGFloat
        public var lineHeight: CGFloat
        /// 줄 높이를 고정해서 첫 줄 위에 생기는 여분의 절반입니다. view가 위아래 여백을 맞출 때 씁니다.
        public var halfLeading: CGFloat
    }

    public let code: String
    public let language: String?
    /// 줄바꿈하지 않는 코드 본문(글꼴·색·줄 높이 적용)
    public let attributedCode: NSAttributedString
    public let style: Style
    public let lineCount: Int

    public init(code: String, language: String?, attributedCode: NSAttributedString, style: Style) {
        self.code = code
        self.language = language
        self.attributedCode = attributedCode
        self.style = style
        var lines = 1
        for unit in code.utf8 where unit == 0x0A { lines += 1 }
        lineCount = lines
        super.init()
    }

    public override func size(forAvailableWidth width: CGFloat) -> CGSize {
        CGSize(width: width, height: CGFloat(lineCount) * style.lineHeight + style.paddingY * 2)
    }

    /// 가장 긴 줄의 폭입니다. view를 만들 때만 계산합니다.
    public private(set) lazy var contentWidth: CGFloat = ceil(attributedCode.size().width)
}

// MARK: - Table

public final class TableAttachment: BlockAttachment {
    public struct Style {
        public var borderColor: PlatformColor
        public var borderWidth: CGFloat
        public var headerBackground: PlatformColor
        public var cornerRadius: CGFloat
        public var cellPaddingX: CGFloat
        public var cellPaddingY: CGFloat
        public var minColumnWidth: CGFloat
        public var maxColumnWidth: CGFloat
        public var overflowFactor: CGFloat
        /// 줄 높이를 고정해서 칸의 첫 줄 위에 생기는 여분의 절반입니다. 그릴 때 이만큼 올립니다.
        public var halfLeading: CGFloat
        /// 본문과 같은 어절 줄바꿈 규칙을 칸에도 적용할지
        public var keepsWordsWithHangulTogether: Bool
    }

    /// 첫 행이 머리글입니다.
    public let rows: [[NSAttributedString]]
    public let cells: [[TableCell]]
    public let style: Style
    /// nil이면 본문 폭을 넘지 않습니다(목록이나 인용문 안의 표).
    public let environment: BlockLayoutEnvironment?
    private var cachedLayout: TableLayout?
    private let layoutDelegate = DecorationLayoutDelegate()

    /// 가장 최근에 계산한 배치입니다. view가 그릴 때 씁니다.
    public var currentLayout: TableLayout? { cachedLayout }

    public init(rows: [[NSAttributedString]], style: Style, environment: BlockLayoutEnvironment?) {
        self.rows = rows
        self.style = style
        self.environment = environment
        layoutDelegate.keepsWordsWithHangulTogether = style.keepsWordsWithHangulTogether
        let delegate = layoutDelegate
        cells = rows.map { row in row.map { TableCell(string: $0, delegate: delegate) } }
        super.init()
    }

    /// `width`는 본문 폭입니다. 표가 본문 폭에 들어가지 않으면 `bleedWidth`까지 넓혀 배치합니다.
    public func layout(forAvailableWidth width: CGFloat) -> TableLayout {
        let widest = max(width, environment?.bleedWidth ?? 0)
        if let cachedLayout, abs(cachedLayout.columnWidth - width) < 0.5, abs(cachedLayout.availableWidth - widest) < 0.5 {
            return cachedLayout
        }
        var layout = TableLayout(cells: cells, style: style, columnWidth: width, availableWidth: width)
        if layout.contentSize.width > width + 0.5, widest > width {
            layout = TableLayout(cells: cells, style: style, columnWidth: width, availableWidth: widest)
        }
        cachedLayout = layout
        return layout
    }

    /// 줄에서 차지하는 크기입니다. 폭은 본문 폭을 넘지 않고, 넘치는 부분은 view가 좌우 여백에 그립니다.
    public override func size(forAvailableWidth width: CGFloat) -> CGSize {
        let layout = layout(forAvailableWidth: width)
        return CGSize(width: min(layout.contentSize.width, width), height: layout.contentSize.height)
    }
}

/// 표의 칸 하나입니다. 본문과 같은 TextKit 2 배치를 써서 줄바꿈 규칙과 인라인 코드 배경이 본문과 같게 나옵니다.
public final class TableCell {
    public let string: NSAttributedString
    private let storage = NSTextContentStorage()
    private let manager = NSTextLayoutManager()
    private let container = NSTextContainer(size: .zero)

    init(string: NSAttributedString, delegate: NSTextLayoutManagerDelegate) {
        self.string = string
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.delegate = delegate
        storage.addTextLayoutManager(manager)
        storage.textStorage = NSTextStorage(attributedString: string)
    }

    /// 줄바꿈 없이 한 줄로 놓았을 때의 폭
    public private(set) lazy var naturalWidth: CGFloat = {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        return ceil(string.boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width)
    }()

    private func layOut(width: CGFloat) {
        if abs(container.size.width - width) > 0.01 {
            container.size = CGSize(width: width, height: 0)
        }
        manager.ensureLayout(for: manager.documentRange)
    }

    /// 주어진 폭에 맞춰 줄을 나눴을 때의 높이
    public func height(forWidth width: CGFloat) -> CGFloat {
        guard string.length > 0 else { return 0 }
        layOut(width: width)
        return ceil(manager.usageBoundsForTextContainer.maxY)
    }

    /// 주어진 폭에서 나뉜 줄들의 글자입니다(검증용).
    public func lines(forWidth width: CGFloat) -> [String] {
        layOut(width: width)
        var lines: [String] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                lines.append((line.attributedString.string as NSString).substring(with: line.characterRange))
            }
            return true
        }
        return lines
    }

    /// `origin`을 칸 내용의 왼쪽 위로 삼아 그립니다(위→아래 좌표).
    public func draw(at origin: CGPoint, width: CGFloat, in context: CGContext) {
        guard string.length > 0 else { return }
        layOut(width: width)
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            fragment.draw(at: CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY), in: context)
            return true
        }
    }
}

/// 표의 열 너비와 행 높이를 정하고, 주어진 그래픽 컨텍스트에 그립니다. 좌표는 위에서 아래로 자랍니다.
public final class TableLayout {
    /// 본문 폭
    public let columnWidth: CGFloat
    /// 표가 쓸 수 있는 폭(본문 폭 이상). 이보다 넓으면 가로 스크롤합니다.
    public let availableWidth: CGFloat
    public let columnWidths: [CGFloat]
    public let rowHeights: [CGFloat]
    public let contentSize: CGSize
    private let cells: [[TableCell]]
    private let style: TableAttachment.Style

    /// 화면에 보이는 표의 폭입니다.
    public var visibleWidth: CGFloat {
        min(contentSize.width, availableWidth)
    }

    init(cells: [[TableCell]], style: TableAttachment.Style, columnWidth: CGFloat, availableWidth: CGFloat) {
        self.cells = cells
        self.style = style
        self.columnWidth = columnWidth
        self.availableWidth = availableWidth

        let columnCount = cells.map(\.count).max() ?? 0
        let padding = style.cellPaddingX * 2

        // 1) 줄바꿈 없이 필요한 너비
        var natural = [CGFloat](repeating: 0, count: columnCount)
        for row in cells {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], cell.naturalWidth)
            }
        }
        let capped = natural.map { min($0, style.maxColumnWidth) + padding }
        let minimum = natural.map { min($0, style.minColumnWidth) + padding }

        // 2) 폭 배분. 들어가면 그대로 둡니다. 넘치면 열을 줄이되, 최소 너비까지 줄여야만 들어가는 경우에는
        //    칸이 너무 좁아지므로 조금 넘치게 두고 가로 스크롤합니다.
        let cappedTotal = capped.reduce(0, +)
        let minimumTotal = minimum.reduce(0, +)
        var widths: [CGFloat]
        if cappedTotal <= availableWidth {
            widths = capped
        } else {
            let target = max(availableWidth, min(minimumTotal * 1.35, availableWidth * style.overflowFactor, cappedTotal))
            let flexible = cappedTotal - minimumTotal
            let ratio = flexible > 0 ? max(0, min(1, (target - minimumTotal) / flexible)) : 0
            widths = zip(minimum, capped).map { $0 + ($1 - $0) * ratio }
            if minimumTotal > target { widths = minimum }
        }
        widths = widths.map { $0.rounded() }
        columnWidths = widths

        // 3) 행 높이
        var heights: [CGFloat] = []
        for row in cells {
            var height: CGFloat = 0
            for (column, cell) in row.enumerated() {
                height = max(height, cell.height(forWidth: widths[column] - padding))
            }
            heights.append(height + style.cellPaddingY * 2)
        }
        rowHeights = heights
        contentSize = CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    /// 표 전체를 그립니다(위→아래 좌표의 컨텍스트).
    public func draw(in context: CGContext, dirtyRect: CGRect) {
        let bounds = CGRect(origin: .zero, size: contentSize)
        let inset = style.borderWidth / 2
        let outline = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                             cornerWidth: style.cornerRadius, cornerHeight: style.cornerRadius, transform: nil)

        context.saveGState()
        context.addPath(outline)
        context.clip()
        if let header = rowHeights.first {
            context.setFillColor(style.headerBackground.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: contentSize.width, height: header))
        }
        context.restoreGState()

        var y: CGFloat = 0
        for (rowIndex, row) in cells.enumerated() {
            let height = rowHeights[rowIndex]
            if y + height >= dirtyRect.minY, y <= dirtyRect.maxY {
                var x: CGFloat = 0
                for (column, cell) in row.enumerated() {
                    let width = columnWidths[column]
                    cell.draw(at: CGPoint(x: x + style.cellPaddingX, y: y + style.cellPaddingY - style.halfLeading),
                              width: width - style.cellPaddingX * 2, in: context)
                    x += width
                }
            }
            y += height
        }

        guard style.borderWidth > 0 else { return }
        context.setStrokeColor(style.borderColor.cgColor)
        context.setLineWidth(style.borderWidth)
        y = 0
        for height in rowHeights.dropLast() {
            y += height
            context.move(to: CGPoint(x: 0, y: y.rounded() - inset))
            context.addLine(to: CGPoint(x: contentSize.width, y: y.rounded() - inset))
        }
        var x: CGFloat = 0
        for width in columnWidths.dropLast() {
            x += width
            context.move(to: CGPoint(x: x - inset, y: 0))
            context.addLine(to: CGPoint(x: x - inset, y: contentSize.height))
        }
        context.strokePath()
        context.addPath(outline)
        context.strokePath()
    }
}

// MARK: - Image

/// 로컬 이미지 파일입니다. 크기는 파일 머리말에서만 읽고, 픽셀은 처음 그릴 때 불러옵니다.
public final class ImageAttachment: NSTextAttachment {
    public let url: URL
    public let pixelSize: CGSize

    /// 파일이 없거나 이미지가 아니면 nil입니다.
    public init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else {
            return nil
        }
        self.url = url
        pixelSize = CGSize(width: width, height: height)
        super.init(data: nil, ofType: nil)
        // `image`를 지정해 두어야 TextKit이 직접 그립니다(메서드 재정의만으로는 그리지 않습니다).
        // 참조만 걸어 두므로 파일은 처음 그릴 때 읽습니다.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        image = NSImage(byReferencing: url)
        #else
        image = UIImage(contentsOfFile: url.path)
        #endif
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 픽셀 크기를 pt로 보고, 쓸 수 있는 폭을 넘으면 비율을 지켜 줄입니다.
    public func size(forAvailableWidth width: CGFloat) -> CGSize {
        let scale = min(1, width / pixelSize.width)
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }

    public override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        CGRect(origin: .zero, size: size(forAvailableWidth: max(proposedLineFragment.width - position.x, 40)))
    }
}
