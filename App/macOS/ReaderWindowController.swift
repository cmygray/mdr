import AppKit
import MdrKit

/// 문서마다 읽던 자리를 UserDefaults에 기억합니다.
enum ScrollPositionStore {
    private static let key = "scrollPositions"
    private static let limit = 500

    /// `key`는 `DocumentSnapshot.positionKey`입니다. 로컬 파일은 경로, 원격 문서는 기기와 문서 이름표입니다.
    static func anchor(forKey documentKey: String) -> ReadingAnchor? {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let entry = all[documentKey] as? [String: Double],
              let index = entry["index"], let delta = entry["delta"] else { return nil }
        return ReadingAnchor(index: Int(index), delta: CGFloat(delta))
    }

    static func save(_ anchor: ReadingAnchor, forKey documentKey: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[documentKey] = [
            "index": Double(anchor.index),
            "delta": Double(anchor.delta),
            "time": Date().timeIntervalSince1970,
        ]
        if all.count > limit {
            // 오래된 기록부터 지웁니다.
            let sorted = all.sorted {
                (($0.value as? [String: Double])?["time"] ?? 0) < (($1.value as? [String: Double])?["time"] ?? 0)
            }
            for (path, _) in sorted.prefix(all.count - limit) {
                all.removeValue(forKey: path)
            }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let splitController = NSSplitViewController()
    let outlineController = OutlineViewController()
    let readerController = ReaderViewController()
    private var sidebarItem: NSSplitViewItem!
    private var saveWork: DispatchWorkItem?
    private var didDisplay = false

    private var readerDocument: Document? { document as? Document }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    init(document: Document) {
        LaunchClock.mark("windowInitStart")
        let automation = Automation.shared
        let size = automation.windowSize ?? NSSize(width: 1040, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init(window: window)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: outlineController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: readerController)
        contentItem.minimumThickness = 320
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = automation.isActive ? nil : "ReaderSplit"
        window.contentViewController = splitController
        window.setContentSize(size)

        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        // 새 문서를 탭으로 열지 창으로 열지는 시스템 설정(문서를 열 때 탭 선호)을 따릅니다.
        window.tabbingMode = .automatic
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 320)
        if automation.isActive {
            window.setFrameOrigin(NSPoint(x: 80, y: 20))
        } else {
            window.center()
            window.setFrameAutosaveName("ReaderWindow")
        }
        if let visible = automation.sidebarVisible {
            sidebarItem.isCollapsed = !visible
        }

        outlineController.onSelect = { [weak self] item in
            self?.readerController.scroll(toCharacterIndex: item.location)
        }
        readerController.onRender = { [weak self] rendered in
            self?.outlineController.update(rendered.outline)
        }
        readerController.onPositionChange = { [weak self] anchor in
            self?.positionDidChange(anchor)
        }
        readerController.onRetry = { [weak self] in
            self?.readerDocument?.retryLoading()
        }
        if document.source?.isRemote == true {
            // 원격 문서의 창은 다음 실행 때 되살리지 않습니다. 링크의 token이 그때까지 살아 있다는 보장이 없습니다.
            window.isRestorable = false
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance),
                                               name: StyleStore.didChange, object: nil)
        applyAppearance()
        LaunchClock.mark("windowInitEnd")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        if !didDisplay, let readerDocument {
            didDisplay = true
            _ = splitController.view
            window?.layoutIfNeeded()
            LaunchClock.mark("windowReady")
            // 창을 만드는 동안 파싱이 백그라운드에서 진행됐습니다. 거의 끝났으면 잠깐 기다려 내용과 함께 띄우고,
            // 오래 걸리는 큰 문서라면 빈 창을 먼저 띄운 뒤 끝나는 대로 채웁니다.
            // 원격 문서는 기다리지 않습니다. 내용이 네트워크에서 메인 스레드로 도착하므로, 여기서 기다리면 그만큼 늦어질 뿐입니다.
            if readerDocument.source?.isRemote != true {
                readerDocument.waitForContent(timeout: 0.1)
            }
            readerDocument.whenContentIsReady { [weak self] in
                self?.displayContent()
            }
            sourceDidUpdate()
            if readerDocument.content == nil, let state = readerDocument.feed?.state {
                feedStateDidChange(state)
            }
        }
        super.showWindow(sender)
        window?.displayIfNeeded()
        LaunchClock.mark("windowShown")
    }

    private func displayContent() {
        guard let readerDocument else { return }
        let saved = remembersPosition ? readerDocument.positionKey.flatMap(ScrollPositionStore.anchor(forKey:)) : nil
        readerController.display(readerDocument, restoring: saved)
        // 처음 연 화면에서도 지금 읽는 절을 목차에 표시합니다.
        outlineController.highlight(characterIndex: (readerController.currentAnchor()?.index ?? 0) + 1)
        window?.makeFirstResponder(readerController.textView)
        // 창을 띄우기 전이라면 `showWindow`가 띄운 뒤에 한 번만 그립니다.
        if window?.isVisible == true {
            window?.displayIfNeeded()
        }
        LaunchClock.mark("displayed")
        Automation.shared.documentDidDisplay(self)
    }

    func documentDidReload() {
        scrollLog.info("documentDidReload")
        readerController.rerender()
    }

    /// 원격 문서를 내준 기기를 제목 아래에 보여 줍니다.
    func sourceDidUpdate() {
        guard case .remote(let location) = readerDocument?.source else { return }
        window?.subtitle = readerDocument?.remoteHostName ?? location.host
    }

    /// 문서를 가져오는 상태가 바뀌었습니다. 아직 받은 것이 없으면 본문 자리에, 받은 뒤라면 창 아래 띠로 알립니다.
    func feedStateDidChange(_ state: FeedState) {
        scrollLog.info("feed state \(String(describing: state), privacy: .public)")
        switch state {
        case .loading:
            // 금방 도착하면 안내가 깜빡이기만 합니다. 조금 기다린 뒤에도 받지 못했을 때만 보여 줍니다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.readerDocument?.content == nil, self.readerDocument?.feed?.state == .loading else { return }
                self.readerController.showStatus(.loading)
            }
        case .live:
            readerController.showNotice(nil)
        case .failed(let error):
            readerController.showStatus(.failed(title: error.title, detail: error.detail, retryable: error.isRetryable))
            Automation.shared.documentDidFail(self)
        case .stale(let error):
            let tail = error.isRetryable ? "다시 연결하는 중입니다." : "지금 보이는 것은 마지막으로 받은 내용입니다."
            readerController.showNotice("\(error.title). \(tail)")
        }
    }

    @objc private func applyAppearance() {
        switch StyleStore.shared.settings.appearance {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Position

    private func positionDidChange(_ anchor: ReadingAnchor) {
        // 화면 위쪽 조금 아래를 기준으로 절을 고릅니다. 제목이 막 화면에 들어왔을 때 바로 강조되게 합니다.
        outlineController.highlight(characterIndex: anchor.index + 1)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePosition() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 자동화 실행은 `-persist YES`를 줬을 때만 읽던 자리를 저장하고 복원합니다.
    private var remembersPosition: Bool {
        !Automation.shared.isActive || Automation.shared.persistsPosition
    }

    func savePosition() {
        guard remembersPosition, didDisplay, readerDocument?.content != nil,
              let key = readerDocument?.positionKey, let anchor = readerController.currentAnchor() else { return }
        ScrollPositionStore.save(anchor, forKey: key)
    }

    func windowWillClose(_ notification: Notification) {
        saveWork?.cancel()
        savePosition()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
