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

/// 본문 자리에 보여 주는 안내입니다.
enum ReaderStatus: Equatable {
    /// 원격 문서를 가져오는 중
    case loading
    /// 문서를 가져오지 못함. 본문 대신 이유를 보여 줍니다.
    case failed(title: String, detail: String, retryable: Bool)
}

/// 문서를 아직 받지 못했을 때 본문 자리에 보이는 안내입니다.
private final class StatusView: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let retry = NSButton(title: "다시 시도", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.isSelectable = true
        retry.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small

        let stack = NSStackView(views: [spinner, icon, title, detail, retry])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ status: ReaderStatus) {
        switch status {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            icon.isHidden = true
            title.stringValue = "문서를 가져오는 중입니다"
            detail.isHidden = true
            retry.isHidden = true
        case .failed(let titleText, let detailText, let retryable):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: nil)
            title.stringValue = titleText
            detail.stringValue = detailText
            detail.isHidden = false
            retry.isHidden = false
            retry.title = retryable ? "지금 다시 시도" : "다시 시도"
        }
    }
}

/// 본문을 보여 주는 얇은 view입니다. 조판은 MdrKit이 하고, 여기서는 배치와 스크롤만 다룹니다.
final class ReaderViewController: NSViewController, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = ReaderTextView(usingTextLayoutManager: true)
    private let layoutDelegate = DecorationLayoutDelegate()
    private let errorLabel = NSTextField(labelWithString: "")
    /// 문서는 보이지만 변경을 받지 못할 때 창 아래에 띄우는 한 줄
    private let noticeLabel = NSTextField(labelWithString: "")
    private let statusView = StatusView()
    private(set) var status: ReaderStatus?
    private(set) var notice: String?
    var onRetry: (() -> Void)?

    private(set) var rendered: RenderedDocument?
    private(set) var style: ResolvedStyle?
    private weak var document: Document?

    /// 화면 맨 위 글자 위치가 바뀔 때마다 부릅니다(목차 강조, 위치 저장).
    var onPositionChange: ((ReadingAnchor) -> Void)?
    var onRender: ((RenderedDocument) -> Void)?

    /// 이 글자 수까지는 목표 지점 앞을 모두 배치해 정확한 위치로 옮깁니다.
    private static let exactLayoutLimit = 2_000_000

    private var lastAnchor: ReadingAnchor?
    /// 폭이 바뀌는 동안 붙잡아 둔 읽던 자리
    private var heldAnchor: ReadingAnchor?
    private var releaseWork: DispatchWorkItem?
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

        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .white
        noticeLabel.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.95)
        noticeLabel.drawsBackground = true
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.isHidden = true

        // 창 아래의 띠들입니다. 숨긴 것은 자리를 차지하지 않습니다.
        let bands = NSStackView(views: [noticeLabel, errorLabel])
        bands.orientation = .vertical
        bands.alignment = .width
        bands.spacing = 0
        bands.translatesAutoresizingMaskIntoConstraints = false
        // 띠는 글자 길이와 상관없이 창 폭을 다 채웁니다.
        noticeLabel.widthAnchor.constraint(equalTo: bands.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: bands.widthAnchor).isActive = true

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true
        statusView.retry.target = self
        statusView.retry.action = #selector(retryTapped)

        container.addSubview(scrollView)
        container.addSubview(statusView)
        container.addSubview(bands)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bands.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bands.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bands.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        NotificationCenter.default.addObserver(self, selector: #selector(styleDidChange),
                                               name: StyleStore.didChange, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        guard width > 0, abs(width - laidOutWidth) > 0.5 else { return }
        let isFirstLayout = laidOutWidth == 0
        laidOutWidth = width
        if isFirstLayout {
            // 처음 크기가 정해질 때는 되돌릴 자리가 없습니다. 복원할 자리가 있으면 그것만 맞춥니다.
            updateInsets()
            if let lastAnchor { scroll(to: lastAnchor) }
            return
        }
        // 폭이 바뀌는 동안(창 크기 조절, 사이드바 애니메이션)에는 배치가 스크롤 위치를 잠깐씩 움직입니다.
        // 그 값을 읽던 자리로 기록하지 않도록, 바뀌기 전의 자리를 붙잡아 두고 폭이 안정될 때까지 그 자리로 되돌립니다.
        if heldAnchor == nil {
            heldAnchor = lastAnchor ?? currentAnchor()
        }
        updateInsets()
        if let heldAnchor {
            scroll(to: heldAnchor)
        }
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let anchor = self.heldAnchor else { return }
            self.scroll(to: anchor)
            self.heldAnchor = nil
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
        // 가려던 자리(`lastAnchor`)를 기준으로 삼습니다. 원격 이미지가 도착하기 전에는 문서가 실제보다 짧아
        // 지금 보이는 곳이 가려던 곳보다 위에 잘려 있을 수 있습니다.
        var anchor = lastAnchor ?? currentAnchor()
        let before = rendered?.text.string
        render()
        // 읽던 자리는 글자 위치로 기억합니다. 그보다 위쪽 글이 바뀌었으면 그만큼 옮겨 같은 문단을 가리키게 합니다.
        if let before, let after = rendered?.text.string, let index = anchor?.index {
            anchor?.index = TextAnchorMapping.remap(index, from: before, to: after)
        }
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
        if let store = document.feed?.images as? RemoteImageStore {
            store.placeholderTint = style.palette.codeBackground
        }
        let rendered = DocumentRenderer(style: style, source: document.source, images: document.feed?.images).render(content.parsed)
        self.rendered = rendered
        LaunchClock.mark("rendered")
        // 원격 이미지는 문서를 그린 뒤에 도착합니다. 도착하면 그 줄만 다시 배치합니다.
        rendered.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in
            (value as? ImageAttachment)?.onChange = { [weak self] attachment in self?.imageDidChange(attachment) }
        }
        changedImages.removeAll()
        showStatus(nil)

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

    // MARK: Status

    /// 본문 대신 보여 줄 안내를 정합니다. nil이면 본문을 보여 줍니다.
    func showStatus(_ status: ReaderStatus?) {
        _ = view
        self.status = status
        statusView.isHidden = status == nil
        scrollView.isHidden = status != nil
        if let status {
            statusView.show(status)
            // 문서를 받기 전에도 창이 문서와 같은 바탕색이 되게 합니다.
            let palette = StyleStore.shared.resolvedStyle(script: .hangul, appearance: view.effectiveAppearance).palette
            view.layer?.backgroundColor = palette.background.cgColor
        }
    }

    /// 창 아래에 한 줄 안내를 띄웁니다. nil이면 감춥니다.
    func showNotice(_ text: String?) {
        _ = view
        notice = text
        noticeLabel.stringValue = text.map { "  \($0)" } ?? ""
        noticeLabel.isHidden = text == nil
    }

    @objc private func retryTapped() {
        onRetry?()
    }

    // MARK: Images

    private var changedImages: [ImageAttachment] = []

    /// 이미지가 채워졌습니다. 같은 때에 도착한 것들을 모아 한 번에 다시 배치합니다.
    private func imageDidChange(_ attachment: ImageAttachment) {
        changedImages.append(attachment)
        guard changedImages.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.relayoutChangedImages() }
    }

    private func relayoutChangedImages() {
        let changed = Set(changedImages.map(ObjectIdentifier.init))
        changedImages.removeAll()
        guard !changed.isEmpty, let contentStorage = textView.textContentStorage, let storage = contentStorage.textStorage else { return }
        // 화면 위쪽의 이미지가 커지면 읽던 줄이 밀려납니다. 읽던 자리를 붙잡았다가 되돌립니다.
        // 기준은 가려던 자리입니다. 이미지가 빈 상자였던 동안에는 문서가 짧아, 복원한 자리가 맨 아래에 잘려 있을 수 있습니다.
        let anchor = heldAnchor ?? lastAnchor ?? currentAnchor()
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let image = value as? ImageAttachment, changed.contains(ObjectIdentifier(image)) { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        // 다시 배치하는 동안 움직인 스크롤 위치를 읽던 자리로 기록하지 않게 합니다.
        isAdjustingScroll = true
        contentStorage.performEditingTransaction {
            for range in ranges {
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        isAdjustingScroll = false
        if let anchor { scroll(to: anchor) }
        textView.needsDisplay = true
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
        // 위쪽 문단의 높이가 막 바뀐 직후에는(늦게 도착한 이미지 등) 목표 문단의 위치가 아직 옛 값일 수 있습니다.
        // 그래서 화면 배치를 적어도 한 번 확정한 뒤에 다시 재서, 위치가 더 바뀌지 않을 때 멈춥니다.
        var settled = false
        for _ in 0..<5 {
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
            // 문서 맨 위(첫 문단보다 위쪽 여백에 있던 경우)는 여백 크기가 바뀌어도 항상 맨 위입니다.
            let isTop = anchor.index == 0 && anchor.delta <= 0 && !alignToFirstLine
            let target = isTop ? top : min(max(frame.minY + delta + textView.textContainerOrigin.y + top, top), bottom)
            if abs(clip.bounds.minY - target) >= 0.5 {
                clip.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(clip)
            } else if settled {
                break
            }
            layoutManager.textViewportLayoutController.layoutViewport()
            settled = true
        }
        // 요청받은 자리를 기억합니다. 아직 창 크기가 정해지기 전이었다면 배치가 끝난 뒤 다시 맞춥니다.
        lastAnchor = alignToFirstLine ? currentAnchor() : anchor
        if let current = currentAnchor() { onPositionChange?(current) }
    }

    func scroll(toCharacterIndex index: Int) {
        scroll(to: ReadingAnchor(index: index, delta: 0), alignToFirstLine: true)
    }

    @objc private func clipBoundsDidChange() {
        guard !isAdjustingScroll, heldAnchor == nil, abs(scrollView.contentSize.width - laidOutWidth) < 0.5,
              let anchor = currentAnchor() else { return }
        lastAnchor = anchor
        onPositionChange?(anchor)
    }

    // MARK: Links

    /// 글자에 `text`가 든 첫 링크를 누른 것처럼 처리합니다(자동화 검증용). 그런 링크가 없으면 false입니다.
    func clickFirstLink(containing text: String) -> Bool {
        guard let storage = textView.textContentStorage?.textStorage else { return false }
        var found: (Any, Int)?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let value, (storage.string as NSString).substring(with: range).contains(text) else { return }
            found = (value, range.location)
            stop.pointee = true
        }
        guard let (link, index) = found else { return false }
        return textView(textView, clickedOnLink: link, at: index)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else {
            NSSound.beep()
            return true
        }
        // 문서 안의 링크는 믿을 수 없는 입력입니다. 무엇을 열지는 `LinkPolicy`(MdrKit)가 문서의 출처를 보고 정합니다.
        switch LinkPolicy.action(for: url, in: document?.source) {
        case .anchor(let name):
            if let index = rendered?.anchors[name] {
                scroll(toCharacterIndex: index)
            }
        case .openExternally(let target):
            NSWorkspace.shared.open(target)
        case .openDocument(let source):
            DocumentOpener.open(source)
        case .reveal(let file):
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSSound.beep()
            }
        case .deny:
            NSSound.beep()
        }
        return true
    }
}
