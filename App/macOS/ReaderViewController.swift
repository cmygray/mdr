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
    /// 선택한 부분을 붙여 넣기 좋은 글자로 돌려줍니다. 코드 블록과 표의 내용도 들어갑니다.
    func plainTextForSelection() -> String {
        guard let storage = textContentStorage?.textStorage else { return "" }
        return selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 }
            .map { storage.mdrPlainText(in: $0) }
            .joined(separator: "\n")
    }

    override func copy(_ sender: Any?) {
        let text = plainTextForSelection()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

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

    /// 이 글자 수까지는 목표 지점 앞을 모두 배치해 정확한 위치로 옮깁니다.
    private static let exactLayoutLimit = 2_000_000

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
        guard let document, let content = document.content else { return }
        let store = StyleStore.shared
        let style = store.resolvedStyle(script: content.script, appearance: view.effectiveAppearance)
        self.style = style
        renderedScheme = style.options.scheme

        layoutDelegate.keepsWordsWithHangulTogether = style.tokens.body.lineBreak == "hangulWord"
        LaunchClock.mark("renderStart")
        let rendered = DocumentRenderer(style: style, baseURL: document.fileURL).render(content.parsed)
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
        // TextKit 2는 아직 배치하지 않은 문단의 높이를 어림합니다. 어림값으로 옮기면 엉뚱한 곳에 서므로
        // 문서 처음부터 목표 지점까지 실제로 배치해 정확한 위치를 얻습니다. 1MB 문서 전체를 배치하는 데
        // 약 0.25초가 걸렸습니다(2026-11-13 측정). 아주 큰 문서의 뒷부분은 어림값으로 옮긴 뒤 다시 재서 고칩니다.
        if anchor.index <= Self.exactLayoutLimit {
            layoutManager.ensureLayout(for: NSTextRange(location: storage.documentRange.location, end: next)!)
        }
        for _ in 0..<4 {
            layoutManager.ensureLayout(for: NSTextRange(location: location, end: next)!)
            guard let fragment = layoutManager.textLayoutFragment(for: location) else { break }
            let frame = fragment.layoutFragmentFrame
            var delta = min(anchor.delta, frame.height)
            if alignToFirstLine, let first = fragment.textLineFragments.first {
                delta = first.typographicBounds.minY - 20
            }
            // 문서를 막 넣은 직후에는 view의 높이가 아직 갱신되지 않았습니다. 그대로 두면
            // 목표 위치가 문서 밖으로 판단되어 맨 위로 잘리므로, 배치 결과에 맞춰 먼저 키웁니다.
            let contentHeight = layoutManager.usageBoundsForTextContainer.maxY + textView.textContainerInset.height * 2
            if textView.frame.height < contentHeight {
                textView.setFrameSize(NSSize(width: textView.frame.width, height: contentHeight))
            }
            let top = -scrollView.contentInsets.top
            let bottom = max(top, textView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
            let target = min(max(frame.minY + delta + textView.textContainerOrigin.y + top, top), bottom)
            if abs(clip.bounds.minY - target) < 0.5 { break }
            clip.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        // 요청받은 자리를 기억합니다. 아직 창 크기가 정해지기 전이었다면 배치가 끝난 뒤 다시 맞춥니다.
        lastAnchor = alignToFirstLine ? currentAnchor() : anchor
        if let current = currentAnchor() { onPositionChange?(current) }
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
        // 문서 안의 링크는 믿을 수 없는 입력입니다(2단계부터는 원격 문서도 엽니다).
        // 웹·메일 링크만 바깥 앱으로 넘기고, 로컬 파일은 마크다운이면 이 앱으로 열고
        // 그 밖에는 실행하지 않고 Finder에서 보여 주기만 합니다. 나머지 scheme은 열지 않습니다.
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            } else if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSSound.beep()
            }
        default:
            NSSound.beep()
        }
        return true
    }
}
