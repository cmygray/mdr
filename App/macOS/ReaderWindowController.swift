import AppKit
import MdrKit

/// 문서마다 읽던 자리를 UserDefaults에 기억합니다.
enum ScrollPositionStore {
    private static let key = "scrollPositions"
    private static let limit = 500

    static func anchor(for url: URL) -> ReadingAnchor? {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let entry = all[url.standardizedFileURL.path] as? [String: Double],
              let index = entry["index"], let delta = entry["delta"] else { return nil }
        return ReadingAnchor(index: Int(index), delta: CGFloat(delta))
    }

    static func save(_ anchor: ReadingAnchor, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[url.standardizedFileURL.path] = [
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

    init(document: Document) {
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
        window.tabbingMode = .preferred
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
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance),
                                               name: StyleStore.didChange, object: nil)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didDisplay, let readerDocument else { return }
        didDisplay = true
        _ = splitController.view
        window?.layoutIfNeeded()
        let saved = Automation.shared.isActive ? nil : readerDocument.fileURL.flatMap(ScrollPositionStore.anchor(for:))
        readerController.display(readerDocument, restoring: saved)
        window?.makeFirstResponder(readerController.textView)
        window?.displayIfNeeded()
        LaunchClock.mark("displayed")
        Automation.shared.documentDidDisplay(self)
    }

    func documentDidReload() {
        readerController.rerender()
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

    private func savePosition() {
        guard !Automation.shared.isActive, didDisplay,
              let url = readerDocument?.fileURL, let anchor = readerController.currentAnchor() else { return }
        ScrollPositionStore.save(anchor, for: url)
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
