import AppKit
import MdrKit

/// 읽던 자리입니다. 픽셀이 아니라 글자 위치로 기억해서, 폭이나 글자 크기가 바뀌어도 같은 곳으로 돌아갑니다.
struct ReadingAnchor: Equatable {
    /// 화면 맨 위에 걸친 문단의 시작 위치(UTF-16 offset)
    var index: Int
    /// 그 문단의 위쪽 끝에서 화면 위쪽 끝까지의 거리(pt)
    var delta: CGFloat
}

final class ReaderTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        // 스페이스로 한 화면씩 넘깁니다.
        if event.charactersIgnoringModifiers == " " {
            if event.modifierFlags.contains(.shift) {
                enclosingScrollView?.pageUp(nil)
            } else {
                enclosingScrollView?.pageDown(nil)
            }
            return
        }
        super.keyDown(with: event)
    }
}

private final class ReaderContainerView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// 본문을 보여 주는 얇은 view입니다. 조판은 MdrKit이 하고, 여기서는 배치와 스크롤만 다룹니다.
final class ReaderViewController: NSViewController, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = ReaderTextView(usingTextLayoutManager: true)
    private let layoutDelegate = DecorationLayoutDelegate()
    private let errorLabel = NSTextField(labelWithString: "")

    private(set) var rendered: RenderedDocument?
    private(set) var style: ResolvedStyle?
    private weak var document: Document?

    /// 화면 맨 위 글자 위치가 바뀔 때마다 부릅니다(목차 강조, 위치 저장).
    var onPositionChange: ((ReadingAnchor) -> Void)?
    var onRender: ((RenderedDocument) -> Void)?

    private var lastAnchor: ReadingAnchor?
    private var laidOutWidth: CGFloat = 0
    private var isAdjustingScroll = false
    private var renderedScheme: ColorScheme?

    // MARK: View

    override func loadView() {
        let container = ReaderContainerView()
        container.wantsLayer = true
        container.onAppearanceChange = { [weak self] in self?.appearanceDidChange() }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.textLayoutManager?.delegate = layoutDelegate

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        // 본문이 제목 막대 밑으로 지나가지 않게, 제목 막대 아래에서 시작합니다.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .white
        errorLabel.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92)
        errorLabel.drawsBackground = true
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true

        container.addSubview(scrollView)
        container.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        NotificationCenter.default.addObserver(self, selector: #selector(styleDidChange),
                                               name: StyleStore.didChange, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        guard width > 0, abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        updateInsets()
        if let lastAnchor {
            scroll(to: lastAnchor)
        }
    }

    // MARK: Rendering

    func display(_ document: Document, restoring anchor: ReadingAnchor?) {
        self.document = document
        render()
        if let anchor {
            lastAnchor = anchor
            scroll(to: anchor)
        }
    }

    /// 문서 내용이나 스타일이 바뀌었을 때 읽던 자리를 지키며 다시 그립니다.
    func rerender() {
        let anchor = currentAnchor()
        render()
        if let anchor {
            scroll(to: anchor)
        }
    }

    private func render() {
        guard let document else { return }
        let store = StyleStore.shared
        let style = store.resolvedStyle(script: document.script, appearance: view.effectiveAppearance)
        self.style = style
        renderedScheme = style.options.scheme

        let rendered = DocumentRenderer(style: style, baseURL: document.fileURL).render(document.parsed)
        self.rendered = rendered
        LaunchClock.mark("rendered")

        textView.backgroundColor = style.palette.background
        scrollView.backgroundColor = style.palette.background
        view.layer?.backgroundColor = style.palette.background.cgColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
        ]
        textView.textContentStorage?.performEditingTransaction {
            textView.textContentStorage?.textStorage?.setAttributedString(rendered.text)
        }
        updateInsets()

        errorLabel.stringValue = store.lastError.map { "  \($0)" } ?? ""
        errorLabel.isHidden = store.lastError == nil
        onRender?(rendered)
    }

    private func updateInsets() {
        guard let style else { return }
        let width = scrollView.contentSize.width
        let margin = CGFloat(style.tokens.pageMargin)
        let horizontal = max(margin, ((width - style.measure) / 2).rounded(.down))
        let inset = NSSize(width: horizontal, height: CGFloat(style.tokens.pagePaddingY))
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        // 넓은 표가 쓸 수 있는 폭을 알려 주고, 바뀌었으면 다시 배치하게 합니다.
        let bleed = max(0, width - margin * 2)
        if let environment = rendered?.environment, abs(environment.bleedWidth - bleed) > 0.5 {
            environment.bleedWidth = bleed
            if let layoutManager = textView.textLayoutManager {
                layoutManager.invalidateLayout(for: layoutManager.documentRange)
            }
        }
    }

    @objc private func styleDidChange() {
        guard isViewLoaded, document != nil else { return }
        rerender()
    }

    private func appearanceDidChange() {
        guard document != nil, let renderedScheme else { return }
        if StyleStore.shared.scheme(for: view.effectiveAppearance) != renderedScheme {
            rerender()
        }
    }

    // MARK: Position

    private var visibleTop: CGFloat {
        scrollView.contentView.bounds.minY + scrollView.contentInsets.top
    }

    func currentAnchor() -> ReadingAnchor? {
        guard let layoutManager = textView.textLayoutManager,
              let storage = textView.textContentStorage else { return nil }
        let y = visibleTop - textView.textContainerOrigin.y
        guard y > 0, let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 1, y: y)) else {
            return ReadingAnchor(index: 0, delta: min(y, 0))
        }
        let index = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
        return ReadingAnchor(index: index, delta: y - fragment.layoutFragmentFrame.minY)
    }

    /// `alignToFirstLine`이면 문단 위 여백을 건너뛰고 첫 줄을 화면 위쪽 가까이에 둡니다(목차 이동용).
    func scroll(to anchor: ReadingAnchor, alignToFirstLine: Bool = false) {
        guard let layoutManager = textView.textLayoutManager,
              let storage = textView.textContentStorage else { return }
        let length = storage.textStorage?.length ?? 0
        guard length > 0,
              let location = storage.location(storage.documentRange.location, offsetBy: min(max(anchor.index, 0), length - 1)),
              let next = storage.location(location, offsetBy: 1) else { return }

        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        let clip = scrollView.contentView
        // TextKit 2는 화면 밖 문단의 높이를 어림하므로, 옮긴 뒤 다시 재서 맞을 때까지 고칩니다.
        for _ in 0..<4 {
            layoutManager.ensureLayout(for: NSTextRange(location: location, end: next)!)
            guard let fragment = layoutManager.textLayoutFragment(for: location) else { break }
            let frame = fragment.layoutFragmentFrame
            var delta = min(anchor.delta, frame.height)
            if alignToFirstLine, let first = fragment.textLineFragments.first {
                delta = first.typographicBounds.minY - 20
            }
            let top = -scrollView.contentInsets.top
            let bottom = max(top, textView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
            let target = min(max(frame.minY + delta + textView.textContainerOrigin.y + top, top), bottom)
            if abs(clip.bounds.minY - target) < 0.5 { break }
            clip.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        lastAnchor = currentAnchor()
        if let lastAnchor { onPositionChange?(lastAnchor) }
    }

    func scroll(toCharacterIndex index: Int) {
        scroll(to: ReadingAnchor(index: index, delta: 0), alignToFirstLine: true)
    }

    @objc private func clipBoundsDidChange() {
        guard !isAdjustingScroll, abs(scrollView.contentSize.width - laidOutWidth) < 0.5,
              let anchor = currentAnchor() else { return }
        lastAnchor = anchor
        onPositionChange?(anchor)
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else { return true }

        if url.scheme == DocumentRenderer.anchorScheme {
            if let index = rendered?.anchors[url.path] {
                scroll(toCharacterIndex: index)
            }
            return true
        }
        if url.isFileURL, ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
