import CoreText
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformView = UIView
#endif

extension PlatformColor {
    /// `#RRGGBB` 또는 `#RRGGBBAA`. 읽을 수 없으면 nil입니다.
    static func hex(_ string: String) -> PlatformColor? {
        var value = string.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }
}

extension PlatformFont {
    /// 글꼴 자체의 줄 높이(ascent + descent + leading)입니다.
    var naturalLineHeight: CGFloat {
        ascender - descender + leading
    }
}
