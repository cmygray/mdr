import CoreText
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// 토큰 외에 렌더링 결과를 바꾸는 입력입니다(사용자 설정과 문서 성격).
public struct RenderOptions: Equatable, Sendable {
    public var scheme: ColorScheme
    public var script: Script
    /// 사용자가 고른 글자 크기 배율입니다.
    public var fontScale: Double
    /// 사용자가 고른 본문 폭 배율입니다.
    public var measureScale: Double

    public init(scheme: ColorScheme = .light, script: Script = .hangul, fontScale: Double = 1, measureScale: Double = 1) {
        self.scheme = scheme
        self.script = script
        self.fontScale = fontScale
        self.measureScale = measureScale
    }
}

public enum FontRole: Hashable, Sendable {
    case body, heading, mono
}

/// 토큰과 옵션을 실제 글꼴·색·거리(pt)로 풀어낸 결과입니다. 스타일 해석기에 해당합니다.
public final class ResolvedStyle {
    public let tokens: StyleTokens
    public let options: RenderOptions

    /// 본문 글자 크기(pt). 모든 em 단위의 기준입니다.
    public let em: CGFloat
    /// 본문 한 줄의 폭(pt)
    public let measure: CGFloat
    public let bodyLineHeight: CGFloat

    public struct Palette {
        public let background: PlatformColor
        public let text: PlatformColor
        public let heading: PlatformColor
        public let secondaryText: PlatformColor
        public let link: PlatformColor
        public let codeText: PlatformColor
        public let codeBackground: PlatformColor
        public let inlineCodeBackground: PlatformColor
        public let border: PlatformColor
        public let quoteBar: PlatformColor
        public let tableHeaderBackground: PlatformColor
        public let marker: PlatformColor
    }

    public let palette: Palette
    private let colors: StyleTokens.Colors
    private var fontCache: [FontKey: PlatformFont] = [:]
    private var italicCache: [FontKey: PlatformFont] = [:]
    private var namedColors: [String: PlatformColor] = [:]

    private struct FontKey: Hashable {
        var role: FontRole
        var size: CGFloat
        var weight: Double
    }

    public init(tokens: StyleTokens, options: RenderOptions) {
        self.tokens = tokens
        self.options = options
        em = CGFloat(tokens.baseSize * options.fontScale)
        measure = (CGFloat(tokens.measure.value(for: options.script)) * em * CGFloat(options.measureScale)).rounded()
        bodyLineHeight = (em * CGFloat(tokens.body.lineHeight.value(for: options.script))).rounded()

        let colors = options.scheme == .dark ? tokens.colors.dark : tokens.colors.light
        self.colors = colors
        func color(_ hex: String, _ fallback: PlatformColor) -> PlatformColor {
            PlatformColor.token(hex) ?? fallback
        }
        palette = Palette(
            background: color(colors.background, .white),
            text: color(colors.text, .black),
            heading: color(colors.heading, .black),
            secondaryText: color(colors.secondaryText, .gray),
            link: color(colors.link, .blue),
            codeText: color(colors.codeText, .black),
            codeBackground: color(colors.codeBackground, .lightGray),
            inlineCodeBackground: color(colors.inlineCodeBackground, .lightGray),
            border: color(colors.border, .lightGray),
            quoteBar: color(colors.quoteBar, .lightGray),
            tableHeaderBackground: color(colors.tableHeaderBackground, .lightGray),
            marker: color(colors.marker, .gray)
        )
    }

    // MARK: Fonts

    public func font(_ role: FontRole, size: CGFloat, weight: Double) -> PlatformFont {
        let key = FontKey(role: role, size: size, weight: weight)
        if let cached = fontCache[key] { return cached }
        let spec: StyleTokens.FontSpec
        switch role {
        case .body: spec = tokens.fonts.body
        case .heading: spec = tokens.fonts.heading
        case .mono: spec = tokens.fonts.mono
        }
        let font = FontFactory.make(spec, size: size, weight: weight)
        fontCache[key] = font
        return font
    }

    public func italicFont(_ role: FontRole, size: CGFloat, weight: Double) -> PlatformFont {
        let key = FontKey(role: role, size: size, weight: weight)
        if let cached = italicCache[key] { return cached }
        let italic = FontFactory.italic(of: font(role, size: size, weight: weight))
        italicCache[key] = italic
        return italic
    }

    public var bodyFont: PlatformFont {
        font(.body, size: em, weight: tokens.body.weight)
    }

    // MARK: Derived values

    /// modular scale의 `step` 단계 크기(pt)입니다.
    public func scaledSize(step: Double) -> CGFloat {
        (em * CGFloat(pow(tokens.scale, step)) * 2).rounded() / 2
    }

    public func heading(level: Int) -> StyleTokens.Heading {
        let index = min(max(level, 1), tokens.headings.count) - 1
        return tokens.headings[index]
    }

    /// 토큰의 색 이름(`heading`, `secondaryText` 등) 또는 `#RRGGBB`, `accent`를 색으로 바꿉니다.
    public func color(named name: String) -> PlatformColor {
        if let cached = namedColors[name] { return cached }
        let color = PlatformColor.token(colors.hex(named: name)) ?? palette.text
        namedColors[name] = color
        return color
    }

    public var lineBreakStrategy: NSParagraphStyle.LineBreakStrategy {
        switch tokens.body.lineBreak {
        case "hangulWord": return [.hangulWordPriority, .pushOut]
        case "hangulWordOnly": return [.hangulWordPriority]
        case "none": return []
        default: return .standard
        }
    }

    /// 줄 높이를 고정하면 TextKit은 남는 높이를 모두 글자 위에 둡니다. 그 절반입니다.
    /// 이 값만큼 문단 위 간격을 줄이고 아래 간격을 늘리면, 글자가 줄 상자의 세로 가운데에 있는 것처럼 보입니다.
    /// (기준선을 올리는 방식은 쓰지 않습니다. TextKit 2가 올린 만큼 줄 높이를 줄여 버립니다.)
    public func halfLeading(for font: PlatformFont, lineHeight: CGFloat) -> CGFloat {
        max(0, (lineHeight - font.naturalLineHeight) / 2)
    }
}
