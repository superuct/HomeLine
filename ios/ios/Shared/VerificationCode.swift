import Foundation

enum VerificationCode {
    static let category = "homeline.verification-code"
    static let copyAction = "homeline.copy-verification-code"

    private static let keyword = #"(?:验证码|驗證碼|校验码|校驗碼|动态密码|動態密碼|动态口令|一次性密码|一次性密碼|verification\s+code|security\s+code|login\s+code|one[- ]time\s+(?:code|password|passcode)|\bOTP\b)"#
    private static let code = #"(?<![a-z0-9])((?=[a-z0-9]{4,8}(?![a-z0-9]))(?=[a-z0-9]{0,7}[0-9])[a-z0-9]{4,8})(?![a-z0-9])"#
    private static let patterns = [
        keyword + #"[\s:：为為是\[\]【】()（）「」『』-]*(?:is\s+)?"# + code,
        code + #"\s*(?:是|为|為|is\s+(?:your|the))\s*(?:您[的]?|你的)?\s*"# + keyword,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func hasCandidate(in text: String) -> Bool {
        patterns.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    static func extract(from text: String) -> String? {
        var candidates = Set<String>()
        // Look for every explicitly labelled code. A message with different
        // codes, or a split code we would only copy part of, needs manual review.
        for result in patterns.flatMap({ $0.matches(in: text, range: NSRange(text.startIndex..., in: text)) }) {
            guard let range = Range(result.range(at: 1), in: text) else { continue }
            let before = text[..<range.lowerBound]
            let after = text[range.upperBound...]
            if before.range(of: #"[0-9][-–— ]$"#, options: .regularExpression) != nil ||
                after.range(of: #"^[-–— ][0-9]"#, options: .regularExpression) != nil { return nil }
            candidates.insert(String(text[range]))
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    static func isSMS(_ userInfo: [AnyHashable: Any]) -> Bool {
        ["sms", "messages"].contains(userInfo["open"] as? String ?? "")
    }
}
