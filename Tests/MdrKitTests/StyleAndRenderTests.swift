import CoreText
import XCTest
@testable import MdrKit

final class StyleTokensTests: XCTestCase {
    func testBundledTokensDecode() {
        XCTAssertEqual(StyleTokens.bundled.headings.count, 6)
        XCTAssertGreaterThan(StyleTokens.bundled.baseSize, 0)
    }

    func testPartialFileKeepsDefaultsForMissingKeys() throws {
        let tokens = try StyleTokens.load(from: Data(#"{"baseSize": 20, "body": {"lineHeight": 1.8}}"#.utf8))
        XCTAssertEqual(tokens.baseSize, 20)
        XCTAssertEqual(tokens.body.lineHeight, .init(hangul: 1.8, latin: 1.8))
        XCTAssertEqual(tokens.body.paragraphSpacing, StyleTokens.bundled.body.paragraphSpacing)
        XCTAssertEqual(tokens.colors, StyleTokens.bundled.colors)
    }

    func testInvalidFileReportsWhere() {
        XCTAssertThrowsError(try StyleTokens.load(from: Data(#"{"body": {"weight": "bold"}}"#.utf8))) { error in
            XCTAssertTrue("\(error)".contains("body.weight"), "\(error)")
        }
        XCTAssertThrowsError(try StyleTokens.load(from: Data("{ not json".utf8)))
    }

    func testModularScale() {
        let style = ResolvedStyle(tokens: .bundled, options: RenderOptions())
        let sizes = (1...4).map { style.scaledSize(step: style.heading(level: $0).step) }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "제목은 단계가 낮을수록 작아야 합니다")
        // 이웃한 단계의 비율이 토큰의 scale(1.2)과 거의 같아야 합니다(0.5pt 단위로 반올림).
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) {
            XCTAssertEqual(Double(larger / smaller), StyleTokens.bundled.scale, accuracy: 0.03)
        }
    }

    func testFontScaleAndMeasure() {
        let base = ResolvedStyle(tokens: .bundled, options: RenderOptions(script: .hangul))
        let larger = ResolvedStyle(tokens: .bundled, options: RenderOptions(script: .hangul, fontScale: 1.25, measureScale: 1.5))
        XCTAssertEqual(larger.em, base.em * 1.25)
        XCTAssertEqual(larger.measure, (base.measure * 1.25 * 1.5).rounded())
    }

    func testBundledFontCoversHangulAndLatin() {
        let font = ResolvedStyle(tokens: .bundled, options: RenderOptions()).bodyFont
        XCTAssertTrue(CTFontCopyFamilyName(font as CTFont) as String == "Pretendard Variable", "번들 글꼴이 등록되지 않았습니다")
        let characters = Array("한A".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count))
    }

    func testFallbackFontIsUsedForMissingGlyphs() {
        // 라틴 전용 글꼴에 한글 fallback을 지정하면, 한글은 fallback 글꼴로 그려야 합니다.
        let spec = StyleTokens.FontSpec(family: "Menlo", fallbacks: ["Pretendard Variable"])
        let font = FontFactory.make(spec, size: 16, weight: 400)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "a한", attributes: [.font: font]))
        let families = (CTLineGetGlyphRuns(line) as! [CTRun]).map { run -> String in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            return CTFontCopyFamilyName(attributes[kCTFontAttributeName] as! CTFont) as String
        }
        XCTAssertEqual(families, ["Menlo", "Pretendard Variable"])
    }

    func testMissingFamilyFallsBackToSystemFont() {
        let font = FontFactory.make(.init(family: "No Such Font 12345", fallbacks: []), size: 16, weight: 400)
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertFalse(FontFactory.isAvailable(family: "No Such Font 12345"))
    }
}

final class RendererTests: XCTestCase {
    private func render(_ source: String, script: Script = .hangul) -> (RenderedDocument, ResolvedStyle) {
        let style = ResolvedStyle(tokens: .bundled, options: RenderOptions(script: script))
        let rendered = DocumentRenderer(style: style, baseURL: nil).render(MarkdownParser.parse(source))
        return (rendered, style)
    }

    private func paragraphStyle(_ rendered: RenderedDocument, at location: Int) -> NSParagraphStyle {
        rendered.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as! NSParagraphStyle
    }

    func testOutlineAndAnchors() {
        let (rendered, _) = render("# 하나\n\n본문\n\n## 둘 셋\n\n본문\n\n## 둘 셋")
        XCTAssertEqual(rendered.outline.map(\.title), ["하나", "둘 셋", "둘 셋"])
        XCTAssertEqual(rendered.outline.map(\.level), [1, 2, 2])
        XCTAssertEqual(rendered.anchors["둘-셋"], rendered.outline[1].location)
        XCTAssertEqual(rendered.anchors["둘-셋-1"], rendered.outline[2].location)
        let text = rendered.text.string as NSString
        XCTAssertTrue(text.substring(from: rendered.outline[1].location).hasPrefix("둘 셋"))
    }

    func testBodyUsesHangulWordBreakingAndFixedLineHeight() {
        let (rendered, style) = render("읽기 전용 마크다운 리더를 설계하고 있습니다.")
        let paragraph = paragraphStyle(rendered, at: 0)
        XCTAssertTrue(paragraph.lineBreakStrategy.contains(.hangulWordPriority))
        XCTAssertEqual(paragraph.minimumLineHeight, style.bodyLineHeight)
        XCTAssertEqual(paragraph.maximumLineHeight, style.bodyLineHeight)
        let ratio = style.bodyLineHeight / style.em
        XCTAssertTrue((1.6...1.75).contains(ratio), "한글 본문 행간 \(ratio)")
    }

    func testSpaceAboveHeadingIsLargerThanBelow() {
        let (rendered, style) = render("문단 하나\n\n## 제목\n\n문단 둘")
        let heading = rendered.outline[0].location
        let headingStyle = paragraphStyle(rendered, at: heading)
        let nextParagraph = (rendered.text.string as NSString).range(of: "문단 둘").location
        let nextStyle = paragraphStyle(rendered, at: nextParagraph)

        // 화면에 보이는 간격 = 앞 문단의 아래 간격 + 이 문단의 위 간격
        let previousStyle = paragraphStyle(rendered, at: 0)
        let above = previousStyle.paragraphSpacing + headingStyle.paragraphSpacingBefore
        let below = headingStyle.paragraphSpacing + nextStyle.paragraphSpacingBefore
        XCTAssertGreaterThan(above, below * 2)
        let token = style.heading(level: 2)
        XCTAssertGreaterThan(token.spaceBefore, token.spaceAfter)
    }

    func testListItemsUseHangingIndent() {
        let (rendered, _) = render("- 첫 항목\n- 둘째 항목")
        let paragraph = paragraphStyle(rendered, at: 0)
        XCTAssertGreaterThan(paragraph.headIndent, paragraph.firstLineHeadIndent)
        XCTAssertTrue(rendered.text.string.hasPrefix("\t•\t첫 항목"))
    }

    func testBlockAttachments() {
        let (rendered, _) = render("```swift\nlet a = 1\nlet b = 2\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        var attachments: [NSTextAttachment] = []
        rendered.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
        }
        XCTAssertEqual(attachments.count, 2)
        let code = attachments[0] as? CodeBlockAttachment
        XCTAssertEqual(code?.lineCount, 2)
        XCTAssertEqual(code?.language, "swift")
        XCTAssertNotNil(attachments[1] as? TableAttachment)
    }

    func testPlainTextIncludesCodeAndTableContents() {
        let (rendered, _) = render("문단 하나\n\n```\nswift build\nswift test\n```\n\n| 구성 | 기술 |\n|---|---|\n| 앱 | `Swift` |\n\n끝")
        let text = rendered.text.mdrPlainText(in: NSRange(location: 0, length: rendered.text.length))
        XCTAssertEqual(text, "문단 하나\nswift build\nswift test\n구성\t기술\n앱\tSwift\n끝")
    }

    func testWideTableUsesBleedWidthThenScrolls() {
        let cell = String(repeating: "넓은 칸의 내용입니다 ", count: 8)
        let (rendered, _) = render("| 하나 | 둘 | 셋 |\n|---|---|---|\n| \(cell) | \(cell) | \(cell) |")
        guard let table = rendered.text.attribute(.attachment, at: 0, effectiveRange: nil) as? TableAttachment else {
            return XCTFail("표가 없습니다")
        }
        // 여백을 쓸 수 없으면 본문 폭보다 넓어 가로 스크롤합니다.
        let narrow = table.layout(forAvailableWidth: 500)
        XCTAssertGreaterThan(narrow.contentSize.width, 500)
        XCTAssertEqual(table.size(forAvailableWidth: 500).width, 500)

        // 여백을 쓸 수 있으면 그만큼 넓혀 배치합니다. 줄에서 차지하는 폭은 본문 폭 그대로입니다.
        rendered.environment.bleedWidth = 900
        let wide = table.layout(forAvailableWidth: 500)
        XCTAssertGreaterThan(wide.visibleWidth, 500)
        XCTAssertLessThanOrEqual(wide.visibleWidth, 900)
        XCTAssertLessThan(wide.contentSize.height, narrow.contentSize.height)
        XCTAssertEqual(table.size(forAvailableWidth: 500).width, 500)
    }

    func testRelativeImageBecomesAttachment() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/03-images-typesetting.md")
        let style = ResolvedStyle(tokens: .bundled, options: RenderOptions())
        let source = "![그림](images/line-length.png)\n\n![없음](images/missing.png)"
        let rendered = DocumentRenderer(style: style, baseURL: fixtures).render(MarkdownParser.parse(source))
        let image = try XCTUnwrap(rendered.text.attribute(.attachment, at: 0, effectiveRange: nil) as? ImageAttachment)
        XCTAssertEqual(image.pixelSize, CGSize(width: 500, height: 296))
        XCTAssertEqual(image.size(forAvailableWidth: 250), CGSize(width: 250, height: 148))
        XCTAssertTrue(rendered.text.string.contains("[이미지: 없음]"))
    }

    func testDarkSchemeChangesColors() {
        let light = ResolvedStyle(tokens: .bundled, options: RenderOptions(scheme: .light))
        let dark = ResolvedStyle(tokens: .bundled, options: RenderOptions(scheme: .dark))
        XCTAssertNotEqual(light.palette.background, dark.palette.background)
        XCTAssertNotEqual(light.palette.text, dark.palette.text)
    }
}
