import CoreText
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// 토큰의 글꼴 지정(`FontSpec`)을 실제 글꼴로 바꿉니다. CoreText만 써서 macOS와 iOS에서 같이 동작합니다.
public enum FontFactory {
    private static let weightAxis = 0x7767_6874 // 'wght'

    /// Package에 번들한 글꼴을 이 프로세스에 등록합니다. 여러 번 불러도 됩니다.
    public static func registerBundledFonts() {
        _ = registered
    }

    private static let registered: Bool = {
        guard let directory = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        let fonts = files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
        guard !fonts.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
        return true
    }()

    /// `weight`는 CSS 숫자(100~900)입니다.
    public static func make(_ spec: StyleTokens.FontSpec, size: CGFloat, weight: Double) -> PlatformFont {
        registerBundledFonts()
        let cascade = spec.fallbacks.compactMap { family -> CTFontDescriptor? in
            guard let attributes = attributes(family: family, weight: weight, size: size) else { return nil }
            return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        }

        if let system = systemFont(named: spec.family, size: size, weight: weight) {
            guard !cascade.isEmpty else { return system }
            let extra = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
            return CTFontCreateCopyWithAttributes(system as CTFont, size, nil, extra) as PlatformFont
        }

        guard var attributes = attributes(family: spec.family, weight: weight, size: size) else {
            // 지정한 글꼴이 없으면 시스템 글꼴로 대신합니다.
            return make(.init(family: "system", fallbacks: spec.fallbacks), size: size, weight: weight)
        }
        if !cascade.isEmpty {
            attributes[kCTFontCascadeListAttribute] = cascade
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as PlatformFont
    }

    /// 기울임 글꼴을 돌려줍니다. 글꼴 가족에 기울임이 없으면(Pretendard 등) 글자를 약 11도 기울여 만듭니다.
    /// (`obliqueness` 속성은 TextKit 2에서 그려지지 않아 쓰지 않습니다.)
    public static func italic(of font: PlatformFont) -> PlatformFont {
        // 기울임이 없는 가족에서도 nil 대신 원래 글꼴을 돌려주는 경우가 있어, 실제로 기울임인지 확인합니다.
        if let italic = CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitItalic, .traitItalic),
           CTFontGetSymbolicTraits(italic).contains(.traitItalic) {
            return italic as PlatformFont
        }
        var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &slant, nil) as PlatformFont
    }

    public static func isAvailable(family: String) -> Bool {
        registerBundledFonts()
        return family.hasPrefix("system") || attributes(family: family, weight: 400, size: 12) != nil
    }

    // MARK: Private

    private static func attributes(family: String, weight: Double, size: CGFloat) -> [CFString: Any]? {
        guard !family.hasPrefix("system") else { return nil }
        let probeDescriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let probe = CTFontCreateWithFontDescriptor(probeDescriptor, size, nil)
        guard (CTFontCopyFamilyName(probe) as String).caseInsensitiveCompare(family) == .orderedSame else { return nil }

        var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        if let range = weightAxisRange(of: probe) {
            attributes[kCTFontVariationAttribute] = [weightAxis: min(max(weight, range.lowerBound), range.upperBound)]
        } else {
            attributes[kCTFontTraitsAttribute] = [kCTFontWeightTrait: coreTextWeight(weight)]
        }
        return attributes
    }

    private static func weightAxisRange(of font: CTFont) -> ClosedRange<Double>? {
        guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else { return nil }
        for axis in axes {
            guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? Int, identifier == weightAxis,
                  let minimum = axis[kCTFontVariationAxisMinimumValueKey] as? Double,
                  let maximum = axis[kCTFontVariationAxisMaximumValueKey] as? Double else { continue }
            return minimum...maximum
        }
        return nil
    }

    private static func systemFont(named name: String, size: CGFloat, weight: Double) -> PlatformFont? {
        let systemWeight = PlatformFont.Weight(rawValue: coreTextWeight(weight))
        switch name {
        case "system":
            return PlatformFont.systemFont(ofSize: size, weight: systemWeight)
        case "system-mono":
            return PlatformFont.monospacedSystemFont(ofSize: size, weight: systemWeight)
        case "system-serif", "system-rounded":
            let base = PlatformFont.systemFont(ofSize: size, weight: systemWeight)
            guard let descriptor = base.fontDescriptor.withDesign(name == "system-serif" ? .serif : .rounded) else {
                return base
            }
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return NSFont(descriptor: descriptor, size: size) ?? base
            #else
            return UIFont(descriptor: descriptor, size: size)
            #endif
        default:
            return nil
        }
    }

    /// CSS 굵기(100~900)를 CoreText 굵기(-1~1)로 바꿉니다.
    private static func coreTextWeight(_ css: Double) -> CGFloat {
        let table: [(Double, CGFloat)] = [
            (100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23),
            (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62),
        ]
        if css <= table[0].0 { return table[0].1 }
        for index in 1..<table.count where css <= table[index].0 {
            let (x0, y0) = table[index - 1]
            let (x1, y1) = table[index]
            return y0 + (y1 - y0) * CGFloat((css - x0) / (x1 - x0))
        }
        return table[table.count - 1].1
    }
}
