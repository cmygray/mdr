// 비교 스크린샷을 만들 때 쓰는 작은 도구입니다.
//
//   swiftc -O scripts/shot.swift -o tmp/shot
//   tmp/shot access                      화면 기록 권한이 있으면 "yes", 없으면 "no"
//   tmp/shot window <bundle id>          그 앱의 맨 앞 일반 창: "<창 번호> <폭> <높이>"
//   tmp/shot pixel <그림.png> <x 비율> <y 비율>   그 위치(0~1, 왼쪽 위 기준)의 색: "r g b" (0~1)
//   tmp/shot quit <bundle id>            그 앱을 끝냅니다(끝날 때까지 기다립니다)
//   tmp/shot handler <url>               시스템이 그 주소를 넘겨줄 앱의 경로(없으면 "none")
//   tmp/shot compose <왼쪽.png> <오른쪽.png> <결과.png> <왼쪽 이름> <오른쪽 이름>
//                                        두 그림을 이름표와 함께 나란히 붙입니다.

import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

switch arguments.first {
case "access":
    print(CGPreflightScreenCaptureAccess() ? "yes" : "no")

case "handler":
    guard arguments.count == 2, let url = URL(string: arguments[1]) else { fail("주소가 필요합니다") }
    print(NSWorkspace.shared.urlForApplication(toOpen: url)?.path ?? "none")

case "window":
    guard arguments.count == 2,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1]).first else {
        fail("실행 중인 앱을 찾지 못했습니다")
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    // 목록은 앞에 있는 창부터 나옵니다.
    for window in list {
        guard (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == app.processIdentifier,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
              width >= 300, height >= 200,
              let id = window[kCGWindowNumber as String] as? Int else { continue }
        print("\(id) \(Int(width)) \(Int(height))")
        exit(0)
    }
    fail("창을 찾지 못했습니다")

case "pixel":
    guard arguments.count == 4, let fx = Double(arguments[2]), let fy = Double(arguments[3]),
          let image = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: arguments[1]))) ?? Data()),
          let color = image.colorAt(x: Int(Double(image.pixelsWide - 1) * fx), y: Int(Double(image.pixelsHigh - 1) * fy))?
              .usingColorSpace(.sRGB) else {
        fail("usage: shot pixel <png> <x 0~1> <y 0~1>")
    }
    print(String(format: "%.3f %.3f %.3f", color.redComponent, color.greenComponent, color.blueComponent))

case "quit":
    guard arguments.count == 2 else { fail("usage: shot quit <bundle id>") }
    func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1])
    }
    running().forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while !running().isEmpty, Date() < deadline { usleep(50_000) }
    running().forEach { $0.forceTerminate() }

case "compose":
    guard arguments.count == 6,
          let left = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: arguments[1]))) ?? Data()),
          let right = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: arguments[2]))) ?? Data()) else {
        fail("usage: shot compose <left.png> <right.png> <out.png> <left label> <right label>")
    }
    let gap = 48, margin = 48, header = 96
    let width = margin * 2 + left.pixelsWide + gap + right.pixelsWide
    let height = margin + header + max(left.pixelsHigh, right.pixelsHigh) + margin
    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: canvas) else { fail("그림을 만들 수 없습니다") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    // 좌표는 왼쪽 아래가 원점입니다. 위쪽을 맞춰 놓습니다.
    func place(_ image: NSBitmapImageRep, x: Int, label: String) {
        let y = height - margin - header - image.pixelsHigh
        image.draw(in: NSRect(x: x, y: y, width: image.pixelsWide, height: image.pixelsHigh))
        (label as NSString).draw(at: NSPoint(x: x, y: height - margin - 64), withAttributes: labelAttributes)
    }
    place(left, x: margin, label: arguments[4])
    place(right, x: margin + left.pixelsWide + gap, label: arguments[5])
    NSGraphicsContext.restoreGraphicsState()

    guard let data = canvas.representation(using: .png, properties: [:]) else { fail("PNG로 바꿀 수 없습니다") }
    do { try data.write(to: URL(fileURLWithPath: arguments[3])) } catch { fail("\(error)") }

default:
    fail("usage: shot access | window <bundle id> | quit <bundle id> | compose <left> <right> <out> <left label> <right label>")
}
