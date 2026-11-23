// fixture에 쓰는 그림을 그립니다.
//
//   swift scripts/fixture-images.swift
//
// 그림은 모두 이 코드로 그린 도표입니다. 바깥에서 가져온 이미지는 없습니다.
// 글자는 저장소에 든 Pretendard Variable로 그립니다. 크기는 픽셀 단위로 고정합니다(레티나 배율 없음).
//
// fixtures/images/ (fixture 03, `fixtures/03-images-typesetting.md`)
//   line-length.png    500×296   본문 폭보다 조금 넓은 그림
//   modular-scale.png  1200×400  본문 폭보다 훨씬 넓어 줄여 그려지는 그림
//   line-height.png    500×220
// fixtures/remote/img/ (원격 문서 확인용, `fixtures/remote/index.md`)
//   flow.png           360×213   검증 스크립트가 이 폭(360)을 확인합니다
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("fixtures/images")
let fontFile = root.appendingPathComponent("Sources/MdrKit/Resources/Fonts/PretendardVariable.ttf")
CTFontManagerRegisterFontsForURL(fontFile as CFURL, .process, nil)

func font(_ size: CGFloat, weight: CGFloat = 400) -> NSFont {
    let axis = 0x7767_6874 // 'wght'
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: "Pretendard Variable",
        kCTFontVariationAttribute: [axis: weight],
    ] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let ink = color(0x1F2328), muted = color(0x6B7280), faint = color(0xD5D9E0)
let accent = color(0x2F6FDE), warm = color(0xD9822B), paper = color(0xFFFFFF), panel = color(0xF4F6F8)

/// 왼쪽 위가 원점인 좌표로 그립니다.
struct Canvas {
    let width: CGFloat, height: CGFloat

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fill: NSColor, radius: CGFloat = 0) {
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: height - y - h, width: w, height: h), xRadius: radius, yRadius: radius).fill()
    }

    func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, stroke: NSColor, width lineWidth: CGFloat = 1,
              dash: [CGFloat] = []) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: height - y1))
        path.line(to: NSPoint(x: x2, y: height - y2))
        path.lineWidth = lineWidth
        if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
        stroke.setStroke()
        path.stroke()
    }

    /// 글자의 기준선을 y에 맞춰 그리고 폭을 돌려줍니다. align: 0 왼쪽, 0.5 가운데, 1 오른쪽
    @discardableResult
    func text(_ string: String, _ x: CGFloat, baseline y: CGFloat, font: NSFont, color: NSColor = ink,
              align: CGFloat = 0) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let context = NSGraphicsContext.current!.cgContext
        context.textPosition = CGPoint(x: x - lineWidth * align, y: height - y)
        CTLineDraw(line, context)
        return lineWidth
    }
}

func render(_ name: String, width: Int, height: Int, draw: (Canvas) -> Void) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let canvas = Canvas(width: CGFloat(width), height: CGFloat(height))
    canvas.rect(0, 0, canvas.width, canvas.height, fill: paper)
    draw(canvas)
    NSGraphicsContext.restoreGraphicsState()
    // 투명도 없는 RGB로 저장합니다.
    let opaque = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
    let data = opaque.representation(using: .png, properties: [:])!
    let file = name.contains("/") ? root.appendingPathComponent(name) : output.appendingPathComponent(name)
    try! data.write(to: file)
    print("\(file.path.dropFirst(root.path.count + 1)) \(width)×\(height)")
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// 1. 줄 길이: 같은 분량의 글을 세 가지 폭으로 놓았을 때 줄 수와 눈의 이동 거리
render("line-length.png", width: 500, height: 296) { canvas in
    canvas.text("같은 글, 세 가지 줄 길이", 24, baseline: 36, font: font(17, weight: 650))
    canvas.text("한 줄에 들어가는 한글 글자 수", 24, baseline: 58, font: font(12.5), color: muted)

    // (제목, 한 줄 글자 수, 줄 수, 색)
    let columns: [(String, Int, Int, NSColor)] = [("20자", 20, 12, warm), ("40자", 40, 6, accent), ("80자", 80, 3, warm)]
    let unit: CGFloat = 2.6          // 글자 하나의 폭
    var x: CGFloat = 24
    let top: CGFloat = 96
    for (title, characters, lines, tint) in columns {
        let width = CGFloat(characters) * unit
        canvas.text(title, x, baseline: top - 12, font: font(13, weight: 600), color: tint)
        for index in 0..<lines {
            // 마지막 줄은 짧게 끝납니다.
            let lineWidth = index == lines - 1 ? width * 0.55 : width
            canvas.rect(x, top + CGFloat(index) * 13, lineWidth, 6, fill: index == 0 ? tint : faint, radius: 3)
        }
        x += width + 34
    }
    canvas.line(24, 262, 476, 262, stroke: faint)
    canvas.text("짧으면 줄을 자주 바꾸고, 길면 다음 줄의 첫머리를 놓칩니다.", 24, baseline: 282, font: font(12.5), color: muted)
}

// 2. modular scale: 배율 1.2로 키운 제목 크기 여섯 단계
render("modular-scale.png", width: 1200, height: 400) { canvas in
    canvas.text("배율 1.2로 키운 글자 크기", 48, baseline: 64, font: font(30, weight: 650))
    canvas.text("크기 = 본문 크기 × 1.2ⁿ  (본문 16pt)", 48, baseline: 100, font: font(20), color: muted)

    let base: CGFloat = 16, ratio: CGFloat = 1.2, zoom: CGFloat = 2.2
    let baseline: CGFloat = 290
    canvas.line(48, baseline, 1152, baseline, stroke: faint, width: 2)
    var x: CGFloat = 60
    for step in 0...5 {
        let size = base * pow(ratio, CGFloat(step))
        let drawn = size * zoom
        let width = canvas.text("가Ag", x, baseline: baseline, font: font(drawn, weight: step == 0 ? 400 : 650),
                                color: step == 0 ? ink : accent)
        // 글자 높이를 나타내는 세로 막대
        canvas.line(x - 10, baseline, x - 10, baseline - drawn * 0.74, stroke: step == 0 ? muted : accent, width: 3)
        canvas.text(step == 0 ? "본문" : "n = \(step)", x, baseline: baseline + 40, font: font(19, weight: 600), color: ink)
        canvas.text(String(format: "%.1fpt", size), x, baseline: baseline + 68, font: font(19), color: muted)
        x += width + 62
    }
}

// 3. 행간: 줄 높이와 글자 크기, 그 차이를 위아래로 나눈 여백
render("line-height.png", width: 500, height: 220) { canvas in
    canvas.text("줄 높이 = 글자 크기 × 1.7", 24, baseline: 36, font: font(17, weight: 650))

    let size: CGFloat = 32, lineHeight = size * 1.7       // 16pt 글자를 두 배로 그립니다
    let left: CGFloat = 24, right: CGFloat = 356, top: CGFloat = 62
    let half = (lineHeight - size) / 2
    for index in 0..<2 {
        let y = top + CGFloat(index) * lineHeight
        canvas.rect(left, y, right - left, lineHeight, fill: index == 0 ? panel : paper)
        canvas.rect(left, y + half, right - left, size, fill: accent.withAlphaComponent(0.13))
        canvas.line(left, y, right, y, stroke: faint)
        // 글자 상자(em)의 아래에서 약 22% 위가 기준선입니다.
        canvas.text(index == 0 ? "한글과 Latin 본문" : "둘째 줄의 글자", left + 10, baseline: y + half + size * 0.80,
                    font: font(size))
    }
    canvas.line(left, top + lineHeight * 2, right, top + lineHeight * 2, stroke: faint)

    // 오른쪽 치수 표시
    let x: CGFloat = 374
    canvas.line(x, top, x, top + lineHeight, stroke: ink, width: 1.5)
    canvas.line(x - 4, top, x + 4, top, stroke: ink, width: 1.5)
    canvas.line(x - 4, top + lineHeight, x + 4, top + lineHeight, stroke: ink, width: 1.5)
    canvas.text("줄 높이 27.2pt", x + 10, baseline: top + lineHeight / 2 + 5, font: font(13, weight: 600))

    let second = top + lineHeight
    canvas.line(x, second + half, x, second + half + size, stroke: accent, width: 1.5)
    canvas.line(x - 4, second + half, x + 4, second + half, stroke: accent, width: 1.5)
    canvas.line(x - 4, second + half + size, x + 4, second + half + size, stroke: accent, width: 1.5)
    canvas.text("글자 크기 16pt", x + 10, baseline: second + lineHeight / 2 + 5, font: font(13, weight: 600), color: accent)

    canvas.text("남는 11.2pt를 위아래로 5.6pt씩 나눕니다.", 24, baseline: 200, font: font(12.5), color: muted)
}

// 4. 원격 문서의 흐름: 명령 → 서버 → 링크 → 앱
render("fixtures/remote/img/flow.png", width: 360, height: 213) { canvas in
    canvas.text("원격 문서를 여는 흐름", 18, baseline: 30, font: font(15, weight: 650))

    let boxes: [(String, String, NSColor)] = [("원격 호스트", "mdr 문서.md", accent), ("링크", "mdr://…", warm), ("이 Mac", "mdr 앱", accent)]
    let width: CGFloat = 92, height: CGFloat = 64, top: CGFloat = 58, gap: CGFloat = 24
    var x: CGFloat = 18
    for (index, (title, detail, tint)) in boxes.enumerated() {
        canvas.rect(x, top, width, height, fill: tint.withAlphaComponent(0.12), radius: 8)
        canvas.text(title, x + width / 2, baseline: top + 27, font: font(13, weight: 650), align: 0.5)
        canvas.text(detail, x + width / 2, baseline: top + 47, font: font(11.5), color: muted, align: 0.5)
        if index < boxes.count - 1 {
            let from = x + width + 4, to = x + width + gap - 4, y = top + height / 2
            canvas.line(from, y, to, y, stroke: ink, width: 1.5)
            canvas.line(to - 5, y - 4, to, y, stroke: ink, width: 1.5)
            canvas.line(to - 5, y + 4, to, y, stroke: ink, width: 1.5)
        }
        x += width + gap
    }
    // 앱이 서버에서 문서를 가져오는 방향
    let y: CGFloat = top + height + 26
    canvas.line(18 + width / 2, y, 18 + width * 2.5 + gap * 2, y, stroke: muted, width: 1.5, dash: [4, 3])
    canvas.line(18 + width / 2, y, 18 + width / 2, top + height + 6, stroke: muted, width: 1.5, dash: [4, 3])
    canvas.line(18 + width * 2.5 + gap * 2, y, 18 + width * 2.5 + gap * 2, top + height + 6, stroke: muted, width: 1.5, dash: [4, 3])
    canvas.text("앱이 문서와 이미지를 가져가고, 바뀌면 다시 받습니다", 180, baseline: y + 22, font: font(11.5), color: muted, align: 0.5)
}
