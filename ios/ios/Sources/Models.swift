import Foundation
import Security

struct ConnectionSettings: Codable {
    var apiURL = ""
    var sipHost = ""
    var username = "admin"
    var deviceID = "ec20"
    var sipPort = "5062"
    var sipUser = "1003"
    var unified: Bool?
    var voiceTransport: String?
    var sipTLS = false
}

enum Vault {
    private static let service = "org.example.homeline"
    static func read(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PhoneError.message("无法保存登录凭据：\(status)") }
    }
}

enum PhoneError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct SMSContact: Identifiable, Equatable, Hashable {
    var peer: String
    var deviceID: String
    var imsi: String
    var preview: String
    var timestamp: String
    var unread: Int
    var latestNotifiableID: Int64?
    var latestIncomingID: Int64?
    var lastMessageID: String
    var updatedAt: String
    var imported: Bool
    var id: String { deviceID + "|" + imsi + "|" + peer }
    init(_ row: [String: Any]) {
        peer = row["peer"] as? String ?? ""
        deviceID = row["device_id"] as? String ?? "ec20"
        imsi = row["imsi"] as? String ?? ""
        preview = row["last_content"] as? String ?? ""
        timestamp = smsString(row["last_timestamp"])
        unread = row["unread_count"] as? Int ?? 0
        lastMessageID = smsString(row["last_sms_id"])
        if smsString(row["last_type"]) == "1" {
            latestIncomingID = Int64(lastMessageID)
        }
        updatedAt = smsString(row["updated_at"])
        imported = row["imported"] as? Bool == true
    }
    func summarizing(_ messages: [SMSMessage]) -> SMSContact {
        guard let latest = messages.max(by: SMSMessage.orderedBefore) else { return self }
        var result = self
        result.latestIncomingID = messages.filter { !$0.outgoing }.compactMap { Int64($0.id) }.max()
        result.latestNotifiableID = messages.filter { $0.confirmedIncoming && !$0.outgoing && !$0.imported }.compactMap { Int64($0.id) }.filter { $0 > 0 }.max()
        result.preview = latest.text
        result.timestamp = latest.timestamp
        result.lastMessageID = latest.id
        result.imported = latest.imported
        return result
    }
    static func newestFirst(_ lhs: SMSContact, _ rhs: SMSContact) -> Bool {
        let left = smsDate(lhs.timestamp) ?? .distantPast
        let right = smsDate(rhs.timestamp) ?? .distantPast
        if left != right { return left > right }
        return lhs.id < rhs.id
    }
}

struct SMSMessage: Identifiable {
    var id: String
    var text: String
    var timestamp: String
    var originalTimestamp: String
    var recordedTimestamp: String
    var imported: Bool
    var confirmedIncoming: Bool
    var outgoing: Bool
    var status: String
    var timelineDate: Date?
    init(_ row: [String: Any]) {
        id = smsString(row["id"])
        text = row["content"] as? String ?? row["text"] as? String ?? ""
        originalTimestamp = smsString(row["timestamp"])
        recordedTimestamp = smsString(row["created_at"])
        imported = row["imported"] as? Bool == true
        // Imported history keeps its original date, even when imported today.
        // Live messages use the NAS record clock for both directions.
        let candidates = imported ? [originalTimestamp, recordedTimestamp] : [recordedTimestamp, originalTimestamp]
        timestamp = candidates.first(where: { smsDate($0) != nil }) ?? ""
        timelineDate = smsDate(timestamp)
        let direction = smsString(row["direction"]).lowercased()
        let kind = smsString(row["type"]).lowercased()
        outgoing = row["outgoing"] as? Bool == true || row["is_outgoing"] as? Bool == true
            || ["out", "outgoing", "outbound", "sent", "send"].contains(direction)
            || ["2", "out", "outgoing", "sent"].contains(kind)
        confirmedIncoming = !outgoing && (["1", "in", "incoming", "received", "inbox"].contains(kind)
            || ["in", "incoming", "inbound", "received"].contains(direction)
            || row["outgoing"] as? Bool == false || row["is_outgoing"] as? Bool == false)
        status = outgoing ? "已提交记录" : "收到"
    }
    static func orderedBefore(_ lhs: SMSMessage, _ rhs: SMSMessage) -> Bool {
        let left = lhs.timelineDate ?? .distantPast
        let right = rhs.timelineDate ?? .distantPast
        if left != right { return left < right }
        let leftID = Int64(lhs.id), rightID = Int64(rhs.id)
        if let leftID, let rightID, leftID != rightID { return leftID < rightID }
        if (leftID != nil) != (rightID != nil) { return leftID != nil }
        return lhs.id < rhs.id
    }
}

struct SMSConversationTimeline {
    struct Row: Identifiable {
        let id: String
        let text: String
        let message: SMSMessage?
        let sendingStatus: String?
    }

    private enum Delivery {
        case sending
        case submitted(serverID: String?)
    }

    private struct Outgoing {
        let id: String
        let text: String
        let baseline: Set<String>
        var delivery = Delivery.sending
    }

    private(set) var messages: [SMSMessage]
    private var outgoing: [Outgoing] = []
    private var displayIDs: [String: String] = [:]

    init(messages: [SMSMessage]) { self.messages = messages }

    var rows: [Row] {
        messages.map { Row(id: displayIDs[$0.id] ?? $0.id, text: $0.text, message: $0, sendingStatus: nil) }
            + outgoing.map { draft in
                let status: String
                switch draft.delivery {
                case .sending: status = "正在发送…"
                case .submitted: status = "已提交"
                }
                return Row(id: draft.id, text: draft.text, message: nil, sendingStatus: status)
            }
    }

    mutating func begin(_ text: String) -> String {
        let id = UUID().uuidString
        outgoing.append(Outgoing(id: id, text: text, baseline: Set(messages.map(\.id))))
        return id
    }

    mutating func submit(_ id: String, response: Any) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let serverID = smsString((response as? [String: Any])?["id"])
        outgoing[index].delivery = .submitted(serverID: serverID.isEmpty ? nil : serverID)
    }

    mutating func removeDraft(_ id: String) { outgoing.removeAll { $0.id == id } }

    mutating func replace(with loaded: [SMSMessage]) {
        messages = loaded
        // Match acknowledged server IDs before considering legacy responses without IDs.
        for draft in outgoing {
            guard case let .submitted(serverID?) = draft.delivery,
                  loaded.contains(where: { $0.outgoing && $0.id == serverID }) else { continue }
            displayIDs[serverID] = draft.id
            removeDraft(draft.id)
        }
        for draft in outgoing {
            guard case .submitted(serverID: nil) = draft.delivery,
                  let message = loaded.first(where: {
                      $0.outgoing && $0.text == draft.text && !draft.baseline.contains($0.id) && displayIDs[$0.id] == nil
                  }) else { continue }
            displayIDs[message.id] = draft.id
            removeDraft(draft.id)
        }
    }
}

// Scope this in-memory cache to one server/account. Keep the original contact
// revision separate from the corrected preview so unchanged polls can reuse it.
struct SMSSummaryCache {
    private var entries: [String: (source: SMSContact, summary: SMSContact)] = [:]
    func summary(for source: SMSContact) -> SMSContact? {
        guard let entry = entries[source.id], entry.source == source else { return nil }
        return entry.summary
    }
    mutating func store(_ messages: [SMSMessage], for source: SMSContact) {
        guard !messages.isEmpty else { return }
        entries[source.id] = (source, source.summarizing(messages))
    }
    mutating func retain(_ contacts: [SMSContact]) {
        let ids = Set(contacts.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }
}

private func smsString(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    return String(describing: value)
}

func smsDate(_ string: String) -> Date? {
    if let value = Double(string), value.isFinite {
        return Date(timeIntervalSince1970: abs(value) > 1e12 ? value / 1000 : value)
    }
    // The AT archive writes ISO timestamps with a space between date and time.
    var timestamp = string
    if let separator = timestamp.index(timestamp.startIndex, offsetBy: 10, limitedBy: timestamp.endIndex),
       separator < timestamp.endIndex, timestamp[separator] == " " {
        timestamp.replaceSubrange(separator...separator, with: "T")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
}

func displayTime(_ string: String, seconds: Bool = false) -> String {
    smsDate(string)?.formatted(date: .abbreviated, time: seconds ? .standard : .shortened) ?? "时间未知"
}
