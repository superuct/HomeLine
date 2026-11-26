import Foundation

enum SystemPhoneActions {
    static func number(_ raw: String) -> String? {
        let formatting = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()-（）.‑‑ "))
        let value = raw.components(separatedBy: formatting).joined()
        return value.range(of: #"^\+?[0-9]{2,20}$"#, options: .regularExpression) != nil ? value : nil
    }
    static func phoneURL(_ raw: String) -> URL? { number(raw).flatMap { URL(string: "tel:" + $0) } }
    static func messageURL(_ raw: String) -> URL? { number(raw).flatMap { URL(string: "sms:" + $0) } }
}
