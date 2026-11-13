import AppKit
import MdrKit

/// 코드 블록과 표의 view를 만들어 TextKit에 건넵니다.
final class BlockViewProvider: NSTextAttachmentViewProvider {
    static func install() {
        BlockAttachment.providerFactory = { attachment, parentView, layoutManager, location in
            BlockViewProvider(textAttachment: attachment, parentView: parentView, textLayoutManager: layoutManager, location: location)
        }
    }

    override func loadView() {
        switch textAttachment {
        case let code as CodeBlockAttachment:
            view = CodeBlockView(attachment: code)
        case let table as TableAttachment:
            view = TableBlockView(attachment: table)
        default:
            view = NSView()
        }
    }
}

/// 가로로만 스크롤하는 scroll view입니다. 세로 스크롤은 바깥(본문)으로 넘깁니다.
final class HorizontalScrollView: NSScrollView {
    private var gestureIsHorizontal = false
    private let fade = CAGradientLayer()
    private static let fadeWidth: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        borderType = .noBorder
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
        automaticallyAdjustsContentInsets = false
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateFade),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    /// 내용이 더 있는 쪽 가장자리를 흐리게 해서, 옆으로 넘길 수 있다는 것을 알립니다.
    @objc func updateFade() {
        let overflow = (documentView?.frame.width ?? 0) - contentSize.width
        let offset = contentView.bounds.minX
        let fadesLeft = offset > 0.5
        let fadesRight = offset < overflow - 0.5
        guard bounds.width > 0, fadesLeft || fadesRight else {
            layer?.mask = nil
            return
        }
        let opaque = NSColor.black.cgColor
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        let edge = NSNumber(value: Double(min(Self.fadeWidth / bounds.width, 0.4)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.colors = [fadesLeft ? clear : opaque, opaque, opaque, fadesRight ? clear : opaque]
        fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        layer?.mask = fade
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func scrollWheel(with event: NSEvent) {
        let startsGesture = event.phase == .began || (event.phase == [] && event.momentumPhase == [])
        if startsGesture {
            let canScroll = (documentView?.frame.width ?? 0) > contentSize.width + 0.5
            gestureIsHorizontal = canScroll && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if gestureIsHorizontal {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

final class CodeBlockView: NSView {
    private let scrollView = HorizontalScrollView(frame: .zero)
    private let textView: NSTextView

    init(attachment: CodeBlockAttachment) {
        textView = NSTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        let style = attachment.style

        wantsLayer = true
        layer?.backgroundColor = style.background.cgColor
        layer?.cornerRadius = style.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = style.borderWidth
        layer?.borderColor = style.borderColor.cgColor
        layer?.masksToBounds = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        // 첫 줄 위에 생기는 여분만큼 위 여백을 줄여, 위아래 여백이 같아 보이게 합니다.
        textView.textContainerInset = NSSize(width: style.paddingX, height: max(0, style.paddingY - style.halfLeading))
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContentStorage?.textStorage?.setAttributedString(attachment.attributedCode)
        let height = attachment.size(forAvailableWidth: 0).height
        textView.frame = NSRect(x: 0, y: 0, width: attachment.contentWidth + style.paddingX * 2, height: height)

        scrollView.documentView = textView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 가장 긴 줄까지 포함한 내용의 폭
    var contentWidth: CGFloat { textView.frame.width }

    var horizontalOffset: CGFloat { scrollView.contentView.bounds.minX }

    func scrollHorizontally(to x: CGFloat) {
        let limit = max(0, textView.frame.width - scrollView.contentSize.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(x, 0), limit), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 코드가 블록보다 좁아도 배경 전체를 선택 영역으로 쓰도록 폭을 맞춥니다.
        if textView.frame.width < newSize.width {
            textView.setFrameSize(NSSize(width: newSize.width, height: textView.frame.height))
        }
    }
}

final class TableBlockView: NSView {
    // 첨부가 provider를, provider가 이 view를 붙들고 있습니다. 여기서 첨부를 강하게 붙들면 서로 놓지 못합니다.
    private weak var attachment: TableAttachment?
    private let scrollView = HorizontalScrollView(frame: .zero)
    private let canvas: TableCanvasView

    init(attachment: TableAttachment) {
        self.attachment = attachment
        canvas = TableCanvasView(attachment: attachment)
        super.init(frame: .zero)
        scrollView.documentView = canvas
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 표 전체의 폭
    var contentWidth: CGFloat { canvas.frame.width }

    /// 화면에 보이는 폭(본문 폭보다 넓을 수 있습니다)
    var visibleWidth: CGFloat { scrollView.frame.width }

    var horizontalOffset: CGFloat { scrollView.contentView.bounds.minX }

    func scrollHorizontally(to x: CGFloat) {
        let limit = max(0, canvas.frame.width - scrollView.contentSize.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(x, 0), limit), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        canvas.syncSize()
        // 본문 폭보다 넓은 표는 본문 폭을 가운데에 두고 좌우 여백으로 넓힙니다.
        let visible = attachment?.currentLayout?.visibleWidth ?? newSize.width
        let overflow = max(0, visible - newSize.width)
        scrollView.frame = NSRect(x: -(overflow / 2).rounded(), y: 0, width: visible, height: newSize.height)
        scrollView.updateFade()
    }
}

/// 표를 직접 그리는 view입니다. 배치와 그리기는 공유 코드(`TableLayout`)가 합니다.
final class TableCanvasView: NSView {
    private weak var attachment: TableAttachment?

    init(attachment: TableAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        syncSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func syncSize() {
        guard let layout = attachment?.currentLayout else { return }
        if frame.size != layout.contentSize {
            setFrameSize(layout.contentSize)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = attachment?.currentLayout, let context = NSGraphicsContext.current?.cgContext else { return }
        layout.draw(in: context, dirtyRect: dirtyRect)
    }
}
