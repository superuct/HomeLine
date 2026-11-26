import Foundation

enum ContactAlphabet {
    static func sortKey(_ name: String) -> String {
        (name.applyingTransform(.toLatin, reverse: false) ?? name)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func section(for key: String) -> String {
        guard let first = key.first, first.isASCII, first >= "A", first <= "Z" else { return "#" }
        return String(first)
    }
}
