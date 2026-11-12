import AppKit
import MdrKit

/// 사용자가 메뉴에서 고르는 값입니다. 토큰 파일과 따로 UserDefaults에 둡니다.
struct ReaderSettings: Equatable {
    enum Appearance: String, CaseIterable {
        case system, light, dark
    }

    static let fontScaleSteps: [Double] = [0.8, 0.875, 0.9375, 1, 1.0625, 1.125, 1.25, 1.375, 1.5, 1.75, 2]
    static let measureScaleSteps: [Double] = [0.75, 0.875, 1, 1.125, 1.25, 1.5]

    var fontScale: Double = 1
    var measureScale: Double = 1
    var appearance: Appearance = .system
}

/// 토큰 파일과 사용자 설정을 들고 있다가, 바뀌면 `didChange`로 알립니다.
final class StyleStore {
    static let shared = StyleStore()
    static let didChange = Notification.Name("StyleStoreDidChange")

    private(set) var tokens: StyleTokens = .bundled
    /// 지금 읽고 감시하는 토큰 파일입니다.
    private(set) var tokensURL: URL = StyleTokens.bundledURL
    /// 마지막으로 읽은 토큰 파일에 오류가 있으면 그 내용입니다. 이때는 직전의 정상 값을 계속 씁니다.
    private(set) var lastError: String?
    /// 실행 중에 토큰 파일을 다시 읽은 횟수(처음 읽은 것은 세지 않습니다)
    private(set) var reloadCount = 0
    private var watcher: FileWatcher?

    var settings = ReaderSettings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private init() {
        // 자동화 실행은 사용자의 설정을 읽지도 바꾸지도 않습니다.
        let automation = Automation.shared
        if automation.isActive {
            settings.fontScale = automation.fontScale ?? 1
            settings.appearance = automation.appearance ?? .light
            return
        }
        let defaults = UserDefaults.standard
        if let scale = defaults.object(forKey: "fontScale") as? Double { settings.fontScale = scale }
        if let scale = defaults.object(forKey: "measureScale") as? Double { settings.measureScale = scale }
        if let raw = defaults.string(forKey: "appearance"), let value = ReaderSettings.Appearance(rawValue: raw) {
            settings.appearance = value
        }
    }

    private func saveSettings() {
        guard !Automation.shared.isActive else { return }
        let defaults = UserDefaults.standard
        defaults.set(settings.fontScale, forKey: "fontScale")
        defaults.set(settings.measureScale, forKey: "measureScale")
        defaults.set(settings.appearance.rawValue, forKey: "appearance")
    }

    // MARK: Token file

    /// 사용자가 고쳐 쓰는 토큰 파일의 위치(배포 빌드용)
    static var userTokensURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("mdr/tokens.json")
    }

    /// 읽을 토큰 파일을 정합니다. 앞의 것이 우선입니다.
    /// 1. 환경 변수 `MDR_TOKENS`
    /// 2. 개발 빌드가 Info.plist에 적어 둔 저장소의 토큰 파일
    /// 3. `~/Library/Application Support/mdr/tokens.json`
    /// 4. 앱에 번들된 기본값
    private static func resolveTokensURL() -> URL {
        let manager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["MDR_TOKENS"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "MDRDevTokensPath") as? String,
           !path.isEmpty, manager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if manager.fileExists(atPath: userTokensURL.path) {
            return userTokensURL
        }
        return StyleTokens.bundledURL
    }

    func start() {
        use(Self.resolveTokensURL(), notify: false)
    }

    private func use(_ url: URL, notify: Bool) {
        tokensURL = url
        reload(notify: notify)
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload(notify: true)
        }
    }

    private func reload(notify: Bool) {
        if notify { reloadCount += 1 }
        do {
            let loaded = try StyleTokens.load(from: tokensURL)
            let changed = loaded != tokens || lastError != nil
            tokens = loaded
            lastError = nil
            if notify, changed {
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        } catch {
            lastError = "\(error)"
            NSLog("mdr: %@", "\(error)")
            if notify {
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    /// 편집할 수 있는 토큰 파일을 돌려줍니다. 번들된 기본값을 쓰고 있었다면 사용자 위치로 복사해 그 파일로 바꿉니다.
    func editableTokensURL() throws -> URL {
        guard tokensURL == StyleTokens.bundledURL else { return tokensURL }
        let target = Self.userTokensURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: StyleTokens.bundledURL, to: target)
        }
        use(target, notify: true)
        return target
    }

    // MARK: Resolution

    func scheme(for appearance: NSAppearance) -> ColorScheme {
        switch settings.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system:
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }

    func resolvedStyle(script: Script, appearance: NSAppearance) -> ResolvedStyle {
        ResolvedStyle(tokens: tokens, options: RenderOptions(
            scheme: scheme(for: appearance),
            script: script,
            fontScale: settings.fontScale,
            measureScale: settings.measureScale
        ))
    }
}
