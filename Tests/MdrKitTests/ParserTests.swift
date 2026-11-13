import XCTest
@testable import MdrKit

final class ParserTests: XCTestCase {
    func testHeadingAndParagraph() {
        let document = MarkdownParser.parse("# 제목\n\n본문 **굵게** `code`")
        XCTAssertEqual(document.blocks, [
            .heading(level: 1, content: [.text("제목")]),
            .paragraph([.text("본문 "), .strong([.text("굵게")]), .text(" "), .code("code")]),
        ])
    }

    func testFrontMatterIsRemovedAndTitleExtracted() {
        let source = """
        ---
        title: "[번역] 문서: 제목"
        source: "https://example.com/a"
        tags:
          - "clippings"
        ---
        첫 문단
        """
        let document = MarkdownParser.parse(source)
        XCTAssertEqual(document.frontMatter?.title, "[번역] 문서: 제목")
        XCTAssertEqual(document.frontMatter?.source, "https://example.com/a")
        XCTAssertEqual(document.blocks, [.paragraph([.text("첫 문단")])])
    }

    func testUnclosedFrontMatterIsLeftAlone() {
        let document = MarkdownParser.parse("---\ntitle: x\n\n본문")
        XCTAssertNil(document.frontMatter)
    }

    func testSingleTildeIsNotStrikethrough() {
        // 한국어 문서의 범위 표기(35~45자, 60~75자)가 취소선이 되면 안 됩니다.
        let document = MarkdownParser.parse("한글 35~45자, 영문 60~75자")
        XCTAssertEqual(document.blocks, [.paragraph([.text("한글 35~45자, 영문 60~75자")])])
    }

    func testDoubleTildeIsStrikethrough() {
        let document = MarkdownParser.parse("이건 ~~지움~~ 입니다")
        XCTAssertEqual(document.blocks, [
            .paragraph([.text("이건 "), .strikethrough([.text("지움")]), .text(" 입니다")]),
        ])
    }

    func testFootnoteReferenceAndDefinition() {
        let document = MarkdownParser.parse("본문[^4]에 따라.\n\n[^4]: S. Schulhoff, *The Prompt Report*.")
        XCTAssertEqual(document.blocks, [
            .paragraph([.text("본문"), .footnoteReference("4"), .text("에 따라.")]),
            .footnoteDefinition(label: "4", content: [.text("S. Schulhoff, "), .emphasis([.text("The Prompt Report")]), .text(".")]),
        ])
    }

    func testOneWordFootnoteDefinitionSurvives() {
        // 그대로 두면 cmark가 링크 참조 정의로 읽어 문서에서 지웁니다.
        let document = MarkdownParser.parse("참조[^a]\n\n[^a]: word")
        XCTAssertEqual(document.blocks.last, .footnoteDefinition(label: "a", content: [.text("word")]))
    }

    func testFootnoteSyntaxInsideCodeFenceIsUntouched() {
        let document = MarkdownParser.parse("```\n[^1]: not a footnote\n```")
        XCTAssertEqual(document.blocks, [.codeBlock(language: nil, code: "[^1]: not a footnote")])
    }

    func testInlineHTMLSuperscriptAndLineBreak() {
        let document = MarkdownParser.parse("Qlerify<sup>1</sup>는<br>다음 줄 <span>그대로</span>")
        XCTAssertEqual(document.blocks, [
            .paragraph([.text("Qlerify"), .superscript([.text("1")]), .text("는"), .lineBreak, .text("다음 줄 그대로")]),
        ])
    }

    func testInlineSVGIsOmittedWithItsText() {
        let source = "앞\n\n<svg width=\"10\"><g><text>그림 속 글자</text></g></svg>\n\n<span></span>\n\n뒤"
        XCTAssertEqual(MarkdownParser.parse(source).blocks, [
            .paragraph([.text("앞")]),
            .paragraph([.omitted("SVG")]),
            .paragraph([.text("뒤")]),
        ])
    }

    func testStandaloneImageBecomesImageBlock() {
        let document = MarkdownParser.parse("![대체 글자](images/a.png)\n\n글 안의 ![x](b.png) 이미지")
        XCTAssertEqual(document.blocks.first, .image(ImageRef(source: "images/a.png", alt: "대체 글자")))
        guard case .paragraph(let inlines)? = document.blocks.last else { return XCTFail("문단이 아닙니다") }
        XCTAssertTrue(inlines.contains(.image(ImageRef(source: "b.png", alt: "x"))))
    }

    func testTable() {
        let document = MarkdownParser.parse("| 구성 | 기술 |\n|:---|---:|\n| 앱 | `Swift` |")
        XCTAssertEqual(document.blocks, [
            .table(Table(alignments: [.leading, .trailing],
                         header: [[.text("구성")], [.text("기술")]],
                         rows: [[[.text("앱")], [.code("Swift")]]])),
        ])
    }

    func testNestedListWithCheckbox() {
        let document = MarkdownParser.parse("1. 하나\n   - [x] 끝남\n   - [ ] 남음\n2. 둘")
        guard case .list(let list)? = document.blocks.first else { return XCTFail("목록이 아닙니다") }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.items.count, 2)
        guard case .list(let nested)? = list.items[0].blocks.last else { return XCTFail("중첩 목록이 없습니다") }
        XCTAssertEqual(nested.items.map(\.checkbox), [.checked, .unchecked])
    }

    func testScriptDetection() {
        XCTAssertEqual(Script.detect(in: "읽기 전용 마크다운 리더를 설계하고 있습니다. QuickMD, TextKit 2"), .hangul)
        XCTAssertEqual(Script.detect(in: "Swift Markdown is a Swift package for parsing."), .latin)
        XCTAssertEqual(Script.detect(in: "12345"), .latin)
    }
}
