import AppKit
import MdrKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("appInit")
        FontFactory.registerBundledFonts()
        LaunchClock.mark("fontsRegistered")
        BlockViewProvider.install()
        StyleStore.shared.start()
        LaunchClock.mark("tokensLoaded")
        NSApp.mainMenu = makeMenu()
        // `mdr://` 링크는 Apple Event로 들어옵니다. 파일 열기는 지금처럼 NSDocumentController가 맡습니다.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        LaunchClock.mark("willFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("didFinishLaunching")
        if let link = Automation.shared.remoteLink {
            DocumentOpener.open(link: link)
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let link = URL(string: text) else { return }
        DocumentOpener.open(link: link)
    }

    /// 문서 없이 켜거나, 창이 없을 때 Dock 아이콘을 누르면 빈 문서 대신 열기 창을 띄웁니다.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Automation.shared.isActive
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSApp.activate()
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Actions

    @objc func zoomIn(_ sender: Any?) {
        stepFontScale(by: 1)
    }

    @objc func zoomOut(_ sender: Any?) {
        stepFontScale(by: -1)
    }

    @objc func zoomReset(_ sender: Any?) {
        StyleStore.shared.settings.fontScale = 1
    }

    @objc func widenMeasure(_ sender: Any?) {
        stepMeasureScale(by: 1)
    }

    @objc func narrowMeasure(_ sender: Any?) {
        stepMeasureScale(by: -1)
    }

    @objc func resetMeasure(_ sender: Any?) {
        StyleStore.shared.settings.measureScale = 1
    }

    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let appearance = ReaderSettings.Appearance(rawValue: raw) else { return }
        StyleStore.shared.settings.appearance = appearance
    }

    @objc func openTokensFile(_ sender: Any?) {
        do {
            let url = try StyleStore.shared.editableTokensURL()
            let configuration = NSWorkspace.OpenConfiguration()
            // JSON의 기본 앱이 없을 수 있으므로 TextEdit으로 엽니다.
            let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: configuration)
            } else {
                NSWorkspace.shared.open(url)
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func revealTokensFile(_ sender: Any?) {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try StyleStore.shared.editableTokensURL()])
        } catch {
            NSApp.presentError(error)
        }
    }

    private func stepFontScale(by offset: Int) {
        let store = StyleStore.shared
        store.settings.fontScale = Self.step(store.settings.fontScale, in: ReaderSettings.fontScaleSteps, by: offset)
    }

    private func stepMeasureScale(by offset: Int) {
        let store = StyleStore.shared
        store.settings.measureScale = Self.step(store.settings.measureScale, in: ReaderSettings.measureScaleSteps, by: offset)
    }

    private static func step(_ value: Double, in steps: [Double], by offset: Int) -> Double {
        let nearest = steps.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
        return steps[min(max(nearest + offset, 0), steps.count - 1)]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseAppearance(_:)) {
            let current = StyleStore.shared.settings.appearance.rawValue
            menuItem.state = (menuItem.representedObject as? String) == current ? .on : .off
        }
        return true
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
            return item
        }

        submenu("mdr") { menu in
            add(menu, "mdr에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add(menu, "mdr 가리기", #selector(NSApplication.hide(_:)), "h")
            add(menu, "기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(menu, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "mdr 종료", #selector(NSApplication.terminate(_:)), "q")
        }

        submenu("파일") { menu in
            add(menu, "열기…", #selector(NSDocumentController.openDocument(_:)), "o")
            let recent = add(menu, "최근 사용 열기", nil)
            let recentMenu = NSMenu(title: "최근 사용 열기")
            recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
            add(recentMenu, "메뉴 지우기", #selector(NSDocumentController.clearRecentDocuments(_:)))
            recent.submenu = recentMenu
            menu.addItem(.separator())
            add(menu, "닫기", #selector(NSWindow.performClose(_:)), "w")
        }

        submenu("편집") { menu in
            add(menu, "복사", #selector(NSText.copy(_:)), "c")
            add(menu, "전체 선택", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())
            let find = add(menu, "찾기…", #selector(NSTextView.performFindPanelAction(_:)), "f")
            find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            let next = add(menu, "다음 찾기", #selector(NSTextView.performFindPanelAction(_:)), "g")
            next.tag = Int(NSFindPanelAction.next.rawValue)
            let previous = add(menu, "이전 찾기", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift])
            previous.tag = Int(NSFindPanelAction.previous.rawValue)
        }

        submenu("보기") { menu in
            add(menu, "사이드바 보기/가리기", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
            add(menu, "돌아가기", #selector(ReaderViewController.goBack(_:)), "[")
            menu.addItem(.separator())
            add(menu, "글자 크게", #selector(zoomIn(_:)), "+", target: self)
            add(menu, "글자 작게", #selector(zoomOut(_:)), "-", target: self)
            add(menu, "글자 기본 크기", #selector(zoomReset(_:)), "0", target: self)
            menu.addItem(.separator())
            add(menu, "본문 폭 넓게", #selector(widenMeasure(_:)), "]", [.command, .option], target: self)
            add(menu, "본문 폭 좁게", #selector(narrowMeasure(_:)), "[", [.command, .option], target: self)
            add(menu, "본문 폭 기본값", #selector(resetMeasure(_:)), "0", [.command, .option], target: self)
            menu.addItem(.separator())
            let appearance = add(menu, "모양", nil)
            let appearanceMenu = NSMenu(title: "모양")
            for (title, value) in [("시스템 설정 따르기", "system"), ("라이트", "light"), ("다크", "dark")] {
                add(appearanceMenu, title, #selector(chooseAppearance(_:)), target: self).representedObject = value
            }
            appearance.submenu = appearanceMenu
            menu.addItem(.separator())
            add(menu, "스타일 토큰 파일 열기", #selector(openTokensFile(_:)), ",", [.command, .option], target: self)
            add(menu, "스타일 토큰 파일을 Finder에서 보기", #selector(revealTokensFile(_:)), target: self)
            menu.addItem(.separator())
            add(menu, "전체 화면 시작/종료", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        submenu("윈도우") { menu in
            add(menu, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "확대/축소", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            add(menu, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)))
            NSApp.windowsMenu = menu
        }

        return main
    }
}
