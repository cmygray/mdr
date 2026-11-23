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
///         [-codeScroll 200] [-tableScroll 200] [-outlineRow 12] [-perform "zoomIn:,widenMeasure:"] [-persist YES]
///         [-metrics out.json] [-wait 0.5] [-exit YES]
///
/// 원격 문서는 파일 대신 `-url "mdr://..."`로 엽니다. `-assumeTailscale off`는 Tailscale이 꺼진 것처럼 동작하게 하고,
/// `-followLink "글자"`는 그 글자가 든 첫 링크를 누른 뒤 새로 열린 문서를 찍습니다.
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
    /// 자동화 실행에서도 읽던 자리를 저장하고 복원합니다(위치 기억 검증용).
    private(set) var persistsPosition = false
    /// 화면에 보이는 첫 코드 블록을 가로로 이만큼 스크롤합니다(가로 스크롤 검증용).
    private(set) var codeScroll: CGFloat?
    /// 화면에 보이는 첫 표를 가로로 이만큼 스크롤합니다.
    private(set) var tableScroll: CGFloat?
    /// 목차에서 이 줄을 누른 것처럼 선택합니다(목차 이동 검증용).
    private(set) var outlineRow: Int?
    /// 메뉴 항목의 동작 이름들입니다. 메뉴를 누른 것과 같은 경로로 차례로 실행합니다(메뉴 연결 검증용).
    private(set) var menuActions: [String] = []
    /// 시작할 때 열 `mdr://` 링크
    private(set) var remoteLink: URL?
    /// Tailscale이 꺼진 것처럼 동작합니다(안내 화면 검증용).
    private(set) var assumesTailscaleOff = false
    /// 이 글자가 든 첫 링크를 누릅니다(문서 안 링크 검증용).
    private(set) var followLink: String?
    private var didFollowLink = false
    /// 링크를 눌러 새 문서가 열렸는지
    private var followLinkOpened = false
    private var didFinish = false
    private var rejectedLinkReason: String?

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
            case "-persist": persistsPosition = value == "YES"
            case "-codeScroll": codeScroll = Double(value).map { CGFloat($0) }
            case "-tableScroll": tableScroll = Double(value).map { CGFloat($0) }
            case "-outlineRow": outlineRow = Int(value)
            case "-perform": menuActions = value.split(separator: ",").map(String.init)
            case "-url": remoteLink = URL(string: value)
            case "-assumeTailscale": assumesTailscaleOff = value == "off"
            case "-followLink": followLink = value
            default: break
            }
        }
    }

    /// 받을 수 없는 링크였습니다. 창이 없으므로 이유만 기록하고 끝냅니다.
    func linkWasRejected(_ reason: String) {
        guard isActive else { return }
        rejectedLinkReason = reason
        if let metricsURL {
            let metrics: [String: Any] = ["linkRejected": reason, "documentCount": NSDocumentController.shared.documents.count]
            try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: metricsURL)
        }
        if exitWhenDone { exit(0) }
    }

    /// 문서를 가져오지 못해 안내 화면이 떴습니다. 그 화면을 찍고 끝냅니다.
    func documentDidFail(_ controller: ReaderWindowController) {
        guard isActive, !didFinish else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            // 기다리는 사이에 문서가 도착했다면 그쪽이 마무리합니다.
            guard controller.readerController.status != nil else { return }
            finish(controller)
        }
    }

    func documentDidDisplay(_ controller: ReaderWindowController) {
        guard isActive else { return }
        let reader = controller.readerController
        if let followLink, !didFollowLink {
            // 링크를 누릅니다. 새 문서가 열리면 그 문서가 표시될 때 이어서 진행하고,
            // 열리지 않으면(막힌 링크) 잠시 뒤에 이 문서로 진행합니다.
            didFollowLink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                let before = NSDocumentController.shared.documents.count
                if !reader.clickFirstLink(containing: followLink) {
                    NSLog("mdr: \"%@\"가 든 링크가 없습니다", followLink)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                    guard NSDocumentController.shared.documents.count == before else { return }
                    proceed(controller)
                }
            }
            return
        }
        if followLink != nil { followLinkOpened = true }
        proceed(controller)
    }

    private func proceed(_ controller: ReaderWindowController) {
        let reader = controller.readerController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            for name in menuActions {
                Self.performMenuItem(action: NSSelectorFromString(name), in: controller.window)
            }
            if let outlineRow {
                controller.outlineController.selectRow(outlineRow)
            }
            let outline = reader.rendered?.outline ?? []
            if let scrollHeading, let item = outline.first(where: { $0.title.hasPrefix(scrollHeading) })
                ?? outline.first(where: { $0.title.contains(scrollHeading) }) {
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
        guard !didFinish else { return }
        didFinish = true
        var codeBlock: [String: Any] = [:]
        if let codeScroll, let view: CodeBlockView = Self.firstVisible(in: controller.readerController.textView) {
            view.scrollHorizontally(to: codeScroll)
            controller.window?.displayIfNeeded()
            codeBlock = ["contentWidth": view.contentWidth, "visibleWidth": view.bounds.width, "scrolledTo": view.horizontalOffset]
        }
        var tableBlock: [String: Any] = [:]
        if let tableScroll, let view: TableBlockView = Self.firstVisible(in: controller.readerController.textView) {
            view.scrollHorizontally(to: tableScroll)
            controller.window?.displayIfNeeded()
            tableBlock = ["contentWidth": view.contentWidth, "visibleWidth": view.visibleWidth, "scrolledTo": view.horizontalOffset]
        }
        if let snapshotURL, let window = controller.window {
            snapshot(window, to: snapshotURL)
        }
        if let metricsURL {
            var metrics = Metrics.collect(from: controller.readerController)
            metrics["launchMs"] = LaunchClock.snapshot
            metrics["tokenReloads"] = StyleStore.shared.reloadCount
            metrics["tokenError"] = StyleStore.shared.lastError ?? ""
            metrics["fontScale"] = StyleStore.shared.settings.fontScale
            metrics["measureScale"] = StyleStore.shared.settings.measureScale
            metrics["sidebarCollapsed"] = controller.isSidebarCollapsed
            metrics.merge(Self.sourceMetrics(controller)) { _, new in new }
            if followLink != nil { metrics["followLinkOpened"] = followLinkOpened }
            if let outlineRow { metrics["outlineRowTitle"] = controller.outlineController.title(atRow: outlineRow) ?? "" }
            if !codeBlock.isEmpty { metrics["codeBlock"] = codeBlock }
            if !tableBlock.isEmpty { metrics["tableBlock"] = tableBlock }
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: metricsURL)
            }
        }
        if exitWhenDone {
            controller.savePosition()
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }

    /// 문서의 출처와 가져오기 상태입니다(원격 문서 검증용).
    private static func sourceMetrics(_ controller: ReaderWindowController) -> [String: Any] {
        guard let document = controller.document as? Document else { return [:] }
        let reader = controller.readerController
        var metrics: [String: Any] = [
            "windowTitle": controller.window?.title ?? "",
            "windowSubtitle": controller.window?.subtitle ?? "",
            "positionKey": document.positionKey ?? "",
            "documentCount": NSDocumentController.shared.documents.count,
            "notice": reader.notice ?? "",
        ]
        switch document.source {
        case .file(let url): metrics["source"] = url.path
        case .remote(let location): metrics["source"] = location.url.absoluteString
        case nil: metrics["source"] = ""
        }
        switch document.feed?.state {
        case .loading: metrics["feedState"] = "loading"
        case .live: metrics["feedState"] = "live"
        case .failed: metrics["feedState"] = "failed"
        case .stale: metrics["feedState"] = "stale"
        case nil: metrics["feedState"] = ""
        }
        if case .failed(let title, let detail, let retryable) = reader.status {
            metrics["statusTitle"] = title
            metrics["statusDetail"] = detail
            metrics["statusRetryable"] = retryable
        }
        if let store = document.feed?.images as? RemoteImageStore {
            metrics["remoteImages"] = ["loaded": store.loadedCount, "failed": store.failedCount, "pending": store.pendingCount]
        }
        var pending = 0
        var widths: [Double] = []
        if let text = reader.rendered?.text {
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                guard let image = value as? ImageAttachment else { return }
                if image.isPending { pending += 1 }
                widths.append(Double(image.pixelSize.width))
            }
        }
        metrics["pendingImageAttachments"] = pending
        metrics["imagePixelWidths"] = widths
        return metrics
    }

    /// 주 메뉴에서 그 동작을 가진 항목을 찾아, 사용자가 고른 것처럼 실행합니다.
    /// 대상이 정해지지 않은 항목은 그 창의 응답 경로(first responder부터)로 보냅니다. 자동화 실행은
    /// 앱이 활성 상태가 아닐 수 있어서, 활성 창에 기대지 않고 창을 직접 지정합니다.
    private static func performMenuItem(action: Selector, in window: NSWindow?) {
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let found = item.submenu.flatMap(find(in:)) { return found }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let item = find(in: menu) else {
            NSLog("mdr: 메뉴에 %@ 동작이 없습니다", NSStringFromSelector(action))
            return
        }
        if let target = item.target {
            NSApp.sendAction(action, to: target, from: item)
        } else if window?.firstResponder?.tryToPerform(action, with: item) != true {
            NSLog("mdr: %@ 동작을 받을 대상이 없습니다", NSStringFromSelector(action))
        }
    }

    /// 화면에 보이는 것 가운데 가장 위에 있는 그 종류의 블록 view
    private static func firstVisible<Block: NSView>(in view: NSView) -> Block? {
        let visible = view.visibleRect
        var found: [Block] = []
        func walk(_ candidate: NSView) {
            if let block = candidate as? Block {
                if block.convert(block.bounds, to: view).intersects(visible) { found.append(block) }
                return
            }
            candidate.subviews.forEach(walk)
        }
        walk(view)
        return found.min { $0.convert($0.bounds, to: view).minY < $1.convert($1.bounds, to: view).minY }
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

/// 조판 결과를 숫자로 확인하기 위한 측정입니다. 문서 전체를 배치한 뒤 실제 줄의 위치와 내용을 읽습니다.
enum Metrics {
    /// 줄바꿈 자리의 앞뒤가 모두 글자인 줄바꿈을 셉니다. 낱말 하나가 줄보다 길어 어쩔 수 없는 경우는 따로 셉니다.
    private struct BreakCounter {
        var breaks = 0
        var insideWord = 0
        var forced = 0
        var samples: [String] = []

        mutating func add(line: String, next: String) {
            breaks += 1
            guard let before = line.unicodeScalars.last, let after = next.unicodeScalars.first,
                  CharacterSet.alphanumerics.contains(before), CharacterSet.alphanumerics.contains(after) else { return }
            // 줄 전체가 공백 없는 한 덩어리면 어디서 끊어도 낱말 안입니다.
            if !line.trimmingCharacters(in: .whitespaces).contains(" ") {
                forced += 1
                return
            }
            insideWord += 1
            if samples.count < 12 {
                samples.append(String(line.suffix(12)) + "⏎" + String(next.prefix(12)))
            }
        }

        var dictionary: [String: Any] {
            ["breaks": breaks, "insideWord": insideWord, "forcedByLongWord": forced, "samples": samples]
        }
    }

    static func collect(from reader: ReaderViewController) -> [String: Any] {
        guard let layoutManager = reader.textView.textLayoutManager, let style = reader.style,
              let rendered = reader.rendered else { return [:] }
        // 읽던 자리는 문서 전체를 배치하기 전에 잽니다. 전체 배치는 어림했던 높이를 실제 값으로 바꿔
        // 화면에 보이는 위치를 움직입니다.
        let topIndex = reader.currentAnchor()?.index ?? -1
        let topHeading = rendered.outline.last(where: { $0.location <= topIndex + 1 })?.title ?? ""
        let scrollOffset = reader.scrollView.contentView.bounds.minY
        let layoutStart = Date()
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let fullLayoutMs = (Date().timeIntervalSince(layoutStart) * 10000).rounded() / 10

        var lineLengths: [Int] = []
        var hangulLineLengths: [Int] = []
        var bodyBreaks = BreakCounter()
        var allBreaks = BreakCounter()
        var tableBreaks = BreakCounter()
        var bodyLineHeights: Set<CGFloat> = []
        var bodyLeft = CGFloat.greatestFiniteMagnitude
        var bodyMaxLineWidth: CGFloat = 0
        var quoteParagraphs = 0
        let bodySize = style.em
        let whitespace = CharacterSet.whitespacesAndNewlines
        let originX = reader.textView.textContainerOrigin.x

        // 제목: 글자 크기와, 앞뒤 문단의 줄 상자까지의 실제 거리
        let headingLevels = Dictionary(rendered.outline.map { ($0.location, $0.level) }, uniquingKeysWith: { first, _ in first })
        var headings: [[String: Any]] = []
        var previousBottom: CGFloat?
        var pendingHeading: (level: Int, size: CGFloat, above: CGFloat, bottom: CGFloat)?
        var location = 0

        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { fragment in
            guard let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString else { return true }
            defer { location += paragraph.length }
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            guard let firstLine = lines.first, let lastLine = lines.last, paragraph.length > 0 else { return true }
            let top = frame.minY + firstLine.typographicBounds.minY
            let bottom = frame.minY + lastLine.typographicBounds.maxY

            if let heading = pendingHeading {
                headings.append(["level": heading.level, "size": heading.size, "gapAbove": heading.above, "gapBelow": top - heading.bottom])
                pendingHeading = nil
            }
            if let level = headingLevels[location], let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                pendingHeading = (level, font.pointSize, previousBottom.map { top - $0 } ?? -1, bottom)
            }
            previousBottom = bottom

            if let decoration = paragraph.attribute(.mdrDecoration, at: 0, effectiveRange: nil) as? BlockDecoration,
               !decoration.quoteBars.isEmpty {
                quoteParagraphs += 1
            }
            guard paragraph.attribute(.attachment, at: 0, effectiveRange: nil) == nil else { return true }

            let text = paragraph.string as NSString
            let strings = lines.map { text.substring(with: $0.characterRange) }
            for (line, next) in zip(strings, strings.dropFirst()) {
                allBreaks.add(line: line, next: next)
            }

            // 본문 문단(본문 글자 크기, 들여쓰지 않음)만 따로 봅니다.
            guard let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                  let paragraphStyle = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  abs(font.pointSize - bodySize) < 0.01, paragraphStyle.headIndent == 0 else { return true }
            for (index, line) in lines.enumerated() {
                bodyLineHeights.insert(line.typographicBounds.height.rounded())
                bodyLeft = min(bodyLeft, originX + frame.minX + line.typographicBounds.minX)
                guard index < lines.count - 1 else { continue }
                // 줄 끝 공백을 뺀 실제 글자의 폭
                let trimmed = strings[index].trimmingCharacters(in: whitespace)
                let endIndex = line.characterRange.location + (strings[index] as NSString).range(of: trimmed).upperBound
                let width = endIndex < NSMaxRange(line.characterRange)
                    ? line.locationForCharacter(at: endIndex).x
                    : line.typographicBounds.width
                bodyMaxLineWidth = max(bodyMaxLineWidth, width)
                lineLengths.append(trimmed.count)
                let hangul = trimmed.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                if hangul * 2 > trimmed.count { hangulLineLengths.append(trimmed.count) }
                bodyBreaks.add(line: strings[index], next: strings[index + 1])
            }
            return true
        }

        // 표 칸과 블록 개수
        var images = 0, codeBlocks = 0, tables = 0
        rendered.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in
            switch value {
            case is ImageAttachment: images += 1
            case is CodeBlockAttachment: codeBlocks += 1
            case let table as TableAttachment:
                tables += 1
                guard let layout = table.currentLayout else { return }
                for row in table.cells {
                    for (column, cell) in row.enumerated() {
                        let strings = cell.lines(forWidth: layout.columnWidths[column] - table.style.cellPaddingX * 2)
                        for (line, next) in zip(strings, strings.dropFirst()) {
                            tableBreaks.add(line: line, next: next)
                        }
                    }
                }
            default: break
            }
        }

        func summary(_ values: [Int]) -> [String: Any] {
            guard !values.isEmpty else { return ["count": 0] }
            let sorted = values.sorted()
            return [
                "count": sorted.count,
                "median": sorted[sorted.count / 2],
                "p10": sorted[sorted.count / 10],
                "p90": sorted[sorted.count * 9 / 10],
                "max": sorted[sorted.count - 1],
                "mean": (Double(sorted.reduce(0, +)) / Double(sorted.count) * 10).rounded() / 10,
            ]
        }

        let background = reader.textView.backgroundColor.usingColorSpace(.sRGB)
        return [
            "imageCount": images,
            "codeBlockCount": codeBlocks,
            "tableCount": tables,
            "quoteParagraphCount": quoteParagraphs,
            "footnoteCount": rendered.anchors.keys.filter { $0.hasPrefix("fn-") }.count,
            "headings": headings,
            "script": style.options.script.rawValue,
            "scheme": style.options.scheme.rawValue,
            "bodySize": bodySize,
            "bodyFont": style.bodyFont.fontName,
            "measure": style.measure,
            "bodyLineHeight": style.bodyLineHeight,
            "measuredBodyLineHeights": bodyLineHeights.sorted(),
            "bodyLeft": bodyLeft == .greatestFiniteMagnitude ? -1 : bodyLeft,
            "bodyMaxLineWidth": (bodyMaxLineWidth * 10).rounded() / 10,
            "textContainerInset": [reader.textView.textContainerInset.width, reader.textView.textContainerInset.height],
            "viewWidth": reader.scrollView.contentSize.width,
            "backgroundRGB": [background?.redComponent ?? -1, background?.greenComponent ?? -1, background?.blueComponent ?? -1],
            "charactersPerLine": summary(lineLengths),
            "charactersPerHangulLine": summary(hangulLineLengths),
            "bodyLineBreaks": bodyBreaks.dictionary,
            "allLineBreaks": allBreaks.dictionary,
            "tableLineBreaks": tableBreaks.dictionary,
            "fullLayoutMs": fullLayoutMs,
            "scrollOffset": scrollOffset,
            "topCharacterIndex": topIndex,
            "topHeading": topHeading,
            "outlineCount": rendered.outline.count,
            "textLength": rendered.text.length,
            "documentHeight": reader.textView.frame.height,
        ]
    }
}
