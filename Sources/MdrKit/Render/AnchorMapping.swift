import Foundation

/// 글이 바뀐 뒤에도 읽던 자리를 같은 내용에 두기 위한 계산입니다.
public enum TextAnchorMapping {
    /// 바뀌기 전 글(`old`)의 글자 위치를 바뀐 글(`new`)의 위치로 옮깁니다(UTF-16 offset).
    ///
    /// 바뀐 곳이 한 군데라고 보고 앞뒤의 같은 부분을 찾습니다. 바뀐 곳보다 앞이면 그대로,
    /// 뒤이면 길이 차이만큼 옮기고, 바뀐 곳 안이면 그 자리에 둡니다. 읽던 자리보다 위쪽 문단을 고치거나
    /// 이미지가 대체 글자로 바뀌어도, 읽던 문단이 그대로 화면에 남습니다.
    public static func remap(_ index: Int, from old: String, to new: String) -> Int {
        let before = old as NSString, after = new as NSString
        let oldLength = before.length, newLength = after.length
        guard oldLength != newLength || before != after else { return index }
        var a = [unichar](repeating: 0, count: oldLength)
        var b = [unichar](repeating: 0, count: newLength)
        before.getCharacters(&a, range: NSRange(location: 0, length: oldLength))
        after.getCharacters(&b, range: NSRange(location: 0, length: newLength))

        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[oldLength - 1 - suffix] == b[newLength - 1 - suffix] { suffix += 1 }

        if index <= prefix { return index }
        if index >= oldLength - suffix { return index + (newLength - oldLength) }
        return min(index, max(prefix, newLength - suffix))
    }
}
