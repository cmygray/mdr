import AppKit
import MdrKit

/// 시작부터 각 단계까지 걸린 시간을 잽니다. `-metrics`로 내보냅니다.
enum LaunchClock {
    private static let lock = NSLock()
    private static var marks: [(String, Double)] = []

    /// 프로세스가 만들어진 시각(커널 기록)
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    static func markMain() {
        mark("main")
    }

    /// 같은 이름은 처음 한 번만 기록합니다.
    static func mark(_ name: String) {
        let elapsed = Date().timeIntervalSince(processStart) * 1000
        lock.lock()
        defer { lock.unlock() }
        if !marks.contains(where: { $0.0 == name }) {
            marks.append((name, (elapsed * 10).rounded() / 10))
        }
    }

    static var snapshot: [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: marks)
    }
}

/// 명령줄 인자로 스냅숏과 측정을 자동화합니다. 검증용이며 일반 사용에는 영향을 주지 않습니다.
///
///     mdr.app/Contents/MacOS/mdr FILE -snapshot out.png [-size 1000x690] [-appearance dark]
///         [-scrollTo "제목 일부"] [-scrollFraction 0.5] [-sidebar hide] [-fontScale 1.25]
///         [-metrics out.json] [-wait 0.5] [-exit YES]
final class Automation {
    static let shared = Automation()

    private(set) var snapshotURL: URL?
    private(set) var metricsURL: URL?
    private(set) var windowSize: NSSize?
    private(set) var appearance: ReaderSettings.Appearance?
    private(set) var scrollHeading: String?
    private(set) var scrollFraction: Double?
    private(set) var sidebarVisible: Bool?
    private(set) var fontScale: Double?
    private(set) var wait: TimeInterval = 0.5
    private(set) var exitWhenDone = false

    var isActive: Bool {
        snapshotURL != nil || metricsURL != nil || exitWhenDone
    }

    private init() {
        // 모든 옵션은 `-이름 값` 꼴입니다. AppKit도 명령줄을 같은 규칙으로 읽어서,
        // 이 꼴이 아닌 인자는 열 파일로 취급합니다(파일은 AppKit이 엽니다).
        var arguments = Array(CommandLine.arguments.dropFirst())
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            guard argument.hasPrefix("-"), !arguments.isEmpty else { continue }
            let value = arguments.removeFirst()
            switch argument {
            case "-snapshot": snapshotURL = fileURL(value)
            case "-metrics": metricsURL = fileURL(value)
            case "-size":
                let parts = value.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { windowSize = NSSize(width: parts[0], height: parts[1]) }
            case "-appearance": appearance = ReaderSettings.Appearance(rawValue: value)
            case "-scrollTo": scrollHeading = value
            case "-scrollFraction": scrollFraction = Double(value)
            case "-sidebar": sidebarVisible = value == "show"
            case "-fontScale": fontScale = Double(value)
            case "-wait": wait = Double(value) ?? wait
            case "-exit": exitWhenDone = value == "YES"
            default: break
            }
        }
    }

    func documentDidDisplay(_ controller: ReaderWindowController) {
        guard isActive else { return }
        let reader = controller.readerController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            if let scrollHeading, let item = reader.rendered?.outline.first(where: { $0.title.contains(scrollHeading) }) {
                reader.scroll(toCharacterIndex: item.location)
            } else if let scrollFraction, let length = reader.rendered?.text.length {
                reader.scroll(toCharacterIndex: Int(Double(length) * scrollFraction))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
                finish(controller)
            }
        }
    }

    private func finish(_ controller: ReaderWindowController) {
        if let snapshotURL, let window = controller.window {
            snapshot(window, to: snapshotURL)
        }
        if let metricsURL {
            var metrics = Metrics.collect(from: controller.readerController)
            metrics["launchMs"] = LaunchClock.snapshot
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: metricsURL)
            }
        }
        if exitWhenDone {
            exit(0)
        }
    }

    /// 창 전체(제목 막대 포함)를 PNG로 저장합니다.
    ///
    /// 창 서버가 합성한 결과를 가져오므로 사용자가 보는 화면과 같습니다. 자기 창은 화면 기록 권한 없이도
    /// 가져올 수 있습니다. `CGWindowListCreateImage`는 최신 SDK에서 Swift로 부를 수 없게 막혀 있어
    /// 실행 중에 찾아 부릅니다(개발용 자동화에만 씁니다). 실패하면 view를 직접 그려 저장하는데,
    /// 이 경우 TextKit 2 본문과 유리 재질은 찍히지 않습니다.
    private func snapshot(_ window: NSWindow, to url: URL) {
        window.displayIfNeeded()
        CATransaction.flush()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingAtBestResolution: UInt32 = 1 | (1 << 3)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            if let image = create(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingAtBestResolution)?.takeRetainedValue(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                return
            }
        }
        NSLog("mdr: 합성된 창을 가져오지 못해 view를 직접 그립니다")
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// 조판 결과를 숫자로 확인하기 위한 측정입니다. 문서 전체를 배치한 뒤 본문 줄을 셉니다.
enum Metrics {
    static func collect(from reader: ReaderViewController) -> [String: Any] {
        guard let layoutManager = reader.textView.textLayoutManager, let style = reader.style else { return [:] }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var lineLengths: [Int] = []
        var hangulLineLengths: [Int] = []
        var breaksInsideWord = 0
        var breaks = 0
        var bodyLineHeights: Set<CGFloat> = []
        let bodySize = style.em
        let whitespace = CharacterSet.whitespacesAndNewlines

        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { fragment in
            guard let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString, paragraph.length > 1,
                  let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                  let paragraphStyle = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  abs(font.pointSize - bodySize) < 0.01, paragraphStyle.headIndent == 0 else { return true }
            let lines = fragment.textLineFragments
            let text = paragraph.string as NSString
            for (index, line) in lines.enumerated() {
                bodyLineHeights.insert(line.typographicBounds.height.rounded())
                guard index < lines.count - 1 else { continue }
                let range = line.characterRange
                let content = text.substring(with: range)
                let trimmed = content.trimmingCharacters(in: whitespace)
                lineLengths.append(trimmed.count)
                let hangul = trimmed.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                if hangul * 2 > trimmed.count { hangulLineLengths.append(trimmed.count) }
                // 줄이 끝난 자리의 앞뒤가 모두 글자이면 낱말 안에서 끊긴 것입니다.
                breaks += 1
                let end = NSMaxRange(range)
                if end < text.length, end > 0,
                   let before = Unicode.Scalar(text.character(at: end - 1)),
                   let after = Unicode.Scalar(text.character(at: end)),
                   CharacterSet.alphanumerics.contains(before), CharacterSet.alphanumerics.contains(after) {
                    breaksInsideWord += 1
                }
            }
            return true
        }

        func summary(_ values: [Int]) -> [String: Any] {
            guard !values.isEmpty else { return ["count": 0] }
            let sorted = values.sorted()
            return [
                "count": sorted.count,
                "median": sorted[sorted.count / 2],
                "p10": sorted[sorted.count / 10],
                "p90": sorted[sorted.count * 9 / 10],
                "mean": (Double(sorted.reduce(0, +)) / Double(sorted.count) * 10).rounded() / 10,
            ]
        }

        return [
            "script": style.options.script.rawValue,
            "scheme": style.options.scheme.rawValue,
            "bodySize": bodySize,
            "bodyFont": style.bodyFont.fontName,
            "measure": style.measure,
            "bodyLineHeight": style.bodyLineHeight,
            "measuredBodyLineHeights": bodyLineHeights.sorted(),
            "textContainerInset": [reader.textView.textContainerInset.width, reader.textView.textContainerInset.height],
            "viewWidth": reader.scrollView.contentSize.width,
            "charactersPerLine": summary(lineLengths),
            "charactersPerHangulLine": summary(hangulLineLengths),
            "lineBreaks": breaks,
            "lineBreaksInsideWord": breaksInsideWord,
            "outlineCount": reader.rendered?.outline.count ?? 0,
            "textLength": reader.rendered?.text.length ?? 0,
            "documentHeight": reader.textView.frame.height,
        ]
    }
}
