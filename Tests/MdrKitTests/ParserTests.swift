import XCTest
@testable import MdrKit

final class ParserTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertEqual(MarkdownParser.parse("# hi").blocks, [.heading(level: 1, content: [.text("hi")])])
    }
}
