import CryptoKit
import Foundation

enum SMSReadPositions {
    static func scope(origin: String, username: String, unifiedToken: String?) -> String {
        guard let unifiedToken, !unifiedToken.isEmpty else { return origin + "|" + username }
        let digest = SHA256.hash(data: Data(unifiedToken.utf8))
        return "paired:" + digest.map { String(format: "%02x", $0) }.joined() + "|" + username
    }

    static func migrate(_ positions: inout [String: Int64], from legacyScope: String, to accountScope: String) {
        guard legacyScope != accountScope else { return }
        let prefix = legacyScope + "|"
        for (key, position) in positions where key.hasPrefix(prefix) {
            let stableKey = accountScope + "|" + key.dropFirst(prefix.count)
            positions[stableKey] = max(positions[stableKey] ?? position, position)
            positions.removeValue(forKey: key)
        }
    }
}

struct SMSReadReceipt {
    let contact: SMSContact
    let through: Int64
    let legacyBefore: Date
}

enum SMSNotificationReadState {
    static func isRead(userInfo: [AnyHashable: Any], deliveredAt: Date, receipts: [SMSReadReceipt],
                       scope: String, installation: String?) -> Bool {
        guard ["sms", "messages"].contains(userInfo["open"] as? String ?? ""),
              let sender = userInfo["sender"] as? String, !sender.isEmpty else { return false }
        if let source = userInfo["reading_scope"] as? String, source != scope { return false }
        if let owner = userInfo["installation"] {
            guard let installation, RemotePush.matchesInstallation(owner, registered: installation) else { return false }
        }
        let senderKey = SystemPhoneActions.number(sender).map(ContactNames.key)
        let matches = receipts.filter { receipt in
            if let device = userInfo["device_id"] as? String, !device.isEmpty, device != receipt.contact.deviceID { return false }
            if let sim = userInfo["imsi"] as? String, !sim.isEmpty, sim != receipt.contact.imsi { return false }
            return receipt.contact.peer == sender || (senderKey != nil && SystemPhoneActions.number(receipt.contact.peer).map(ContactNames.key) == senderKey)
        }
        // A legacy notification without a SIM identifier must not guess between SIMs.
        guard matches.count == 1, let receipt = matches.first else { return false }
        if let value = userInfo["message_id"] {
            let id: Int64?
            if let string = value as? String { id = Int64(string) }
            else if let number = value as? NSNumber { id = Int64(number.stringValue) }
            else { id = nil }
            guard let id, id > 0 else { return false }
            return id <= receipt.through
        }
        // Older pushes have no message ID. Retain anything delivered after the
        // read request began, since it may refer to a message outside that response.
        return deliveredAt <= receipt.legacyBefore
    }
}
