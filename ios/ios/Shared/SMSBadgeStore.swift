import Foundation
import Security

enum SMSBadgeStore {
    struct Arrival: Codable {
        let installation: UUID
        let device: String
        let thread: String
        let id: Int64

        init?(_ info: [AnyHashable: Any]) {
            guard VerificationCode.isSMS(info),
                  let owner = info["installation"] as? String, let installation = UUID(uuidString: owner),
                  let device = info["device_id"] as? String, !device.isEmpty,
                  let sender = info["sender"] as? String, !sender.isEmpty,
                  let id = Int64(String(describing: info["message_id"] ?? "")), id > 0 else { return nil }
            self.installation = installation
            self.device = device
            self.id = id
            thread = SMSBadgeStore.thread(device: device, imsi: info["imsi"] as? String ?? "", peer: sender)
        }
    }

    struct Inbox: Codable {
        let installation: UUID
        let device: String
        let through: Int64
        var unread: [String: Int64]
        var readAhead: [String: Int64] = [:]

        func includes(_ arrival: Arrival) -> Bool {
            installation == arrival.installation && device == arrival.device
        }
        func count(with arrivals: [Arrival]) -> Int {
            var threads = Set(unread.keys)
            for arrival in arrivals where includes(arrival) &&
                arrival.id > max(through, readAhead[arrival.thread] ?? 0) {
                threads.insert(arrival.thread)
            }
            return threads.count
        }
        mutating func markRead(thread: String, through id: Int64) {
            if let newest = unread[thread], newest <= id { unread.removeValue(forKey: thread) }
            if id > through { readAhead[thread] = max(readAhead[thread] ?? 0, id) }
        }
    }

    static func thread(device: String, imsi: String, peer: String) -> String {
        let number = peer.allSatisfy { $0.isNumber || "+-() ".contains($0) } ? ContactNames.key(peer) : peer
        return device + "|" + imsi + "|" + number
    }

    static func replaceInbox(_ next: Inbox) -> Int? {
        var snapshot = next
        if let previous = inbox, previous.installation == next.installation, previous.device == next.device {
            for (thread, id) in previous.readAhead { snapshot.markRead(thread: thread, through: id) }
        }
        guard write(snapshot, to: snapshotKey) else { return nil }
        let events = arrivals()
        for event in events where !snapshot.includes(event) || event.id <= snapshot.through {
            delete(eventKey(event))
        }
        return snapshot.count(with: events)
    }

    static func markRead(_ positions: [(String, Int64)], installation: UUID, device: String) -> Int? {
        guard var snapshot = inbox, snapshot.installation == installation, snapshot.device == device else { return nil }
        for (thread, id) in positions { snapshot.markRead(thread: thread, through: id) }
        guard write(snapshot, to: snapshotKey) else { return nil }
        return snapshot.count(with: arrivals())
    }

    static func receive(_ info: [AnyHashable: Any]) -> Int? {
        guard let event = Arrival(info), let before = inbox, before.includes(event) else { return nil }
        if event.id > max(before.through, before.readAhead[event.thread] ?? 0) {
            guard write(event, to: eventKey(event)) else { return nil }
        }
        let events = arrivals()
        guard let current = inbox, current.includes(event) else { return nil }
        return current.count(with: events)
    }

    static func reset() { delete(snapshotKey) }
    #if DEBUG
    static var hasStoredInbox: Bool { inbox != nil }
    #endif

    private static let snapshotKey = "inbox"
    private static let service = "org.example.homeline.sms-badge"
    private static var group: String? { Bundle.main.object(forInfoDictionaryKey: "SMSBadgeKeychainGroup") as? String }
    private static func eventKey(_ event: Arrival) -> String { "\(event.installation.uuidString).\(event.id)" }
    private static func query(_ key: String?) -> [String: Any]? {
        guard let group else { return nil }
        var values: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccessGroup as String: group]
        if let key { values[kSecAttrAccount as String] = key }
        return values
    }
    private static var inbox: Inbox? {
        guard var values = query(snapshotKey) else { return nil }
        values[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Inbox.self, from: data)
    }
    private static func arrivals() -> [Arrival] {
        guard var values = query(nil) else { return [] }
        values[kSecReturnAttributes as String] = true
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item[kSecAttrAccount as String] as? String != snapshotKey, let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(Arrival.self, from: data)
        }
    }
    private static func write<T: Encodable>(_ value: T, to key: String) -> Bool {
        guard var values = query(key), let data = try? JSONEncoder().encode(value) else { return false }
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(values as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(values as CFDictionary, nil)
        return added == errSecSuccess || added == errSecDuplicateItem
    }
    private static func delete(_ key: String) {
        if let values = query(key) { SecItemDelete(values as CFDictionary) }
    }
}
