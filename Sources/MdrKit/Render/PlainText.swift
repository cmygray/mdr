import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

public extension NSAttributedString {
    /// 조판한 문서의 일부를 붙여 넣기 좋은 글자로 바꿉니다.
    ///
    /// 코드 블록과 표는 본문에서 첨부 문자 하나로만 있으므로, 그대로 복사하면 내용이 빠집니다.
    /// 코드 블록은 코드 원문으로, 표는 탭으로 칸을 나눈 줄들로 풀어 씁니다.
    func mdrPlainText(in range: NSRange) -> String {
        var out = ""
        let source = string as NSString
        enumerateAttribute(.attachment, in: range, options: []) { value, subrange, _ in
            switch value {
            case let code as CodeBlockAttachment:
                out += code.code
            case let table as TableAttachment:
                out += table.rows
                    .map { row in row.map { $0.string.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                    .joined(separator: "\n")
            case let image as ImageAttachment:
                out += image.url.lastPathComponent
            default:
                // 문단 안의 강제 줄바꿈(U+2028)은 보통 줄바꿈으로, 남은 첨부 문자는 뺍니다.
                out += source.substring(with: subrange)
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }
}
