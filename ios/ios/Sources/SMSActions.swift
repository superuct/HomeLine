import Foundation

struct SMSSendAttempt {
    static let lengthError = "信息过长。普通文字最多 512 个，部分表情占用更多长度。"
    static func accepts(_ body: String) -> Bool { (1...512).contains(body.utf16.count) }

    let origin: String
    let peer: String
    let body: String
    let id = UUID()

    static func reuse(_ previous: Self?, origin: String, peer: String, body: String) -> Self {
        if let previous, previous.origin == origin, previous.peer == peer, previous.body == body { return previous }
        return Self(origin: origin, peer: peer, body: body)
    }
}

struct SMSItem: Identifiable {
    let contact: SMSContact
    let message: SMSMessage
    var id: String { contact.id + "|" + message.id }
}

enum VerificationSMS {
    static func containsCode(_ message: SMSMessage) -> Bool {
        guard message.confirmedIncoming, !message.outgoing else { return false }
        return VerificationCode.hasCandidate(in: message.text)
    }

    static func code(in message: SMSMessage) -> String? {
        guard message.confirmedIncoming, !message.outgoing else { return nil }
        return VerificationCode.extract(from: message.text)
    }
}

struct SMSScanResult {
    var items: [SMSItem] = []
    var limited = false
}

extension NASClient {
    func sendSMS(_ attempt: SMSSendAttempt, deviceID: String, imsi: String? = nil) async throws -> Any {
        var body = ["device_id": deviceID, "phone": attempt.peer, "message": attempt.body,
                    "request_id": attempt.id.uuidString]
        if let imsi { body["imsi"] = imsi }
        let deadline = ContinuousClock.now + .seconds(80)
        repeat {
            let result = try await request("sms/send", body: body, timeout: 85)
            if (result as? [String: Any])?["state"] as? String != "sending" { return result }
            try await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline
        throw PhoneError.message("NAS 仍在处理这次发送，请稍后查看会话。")
    }

    func scanVerificationMessages() async throws -> SMSScanResult {
        let contacts = try await rows("sms/contacts", query: ["device_id": settings.deviceID, "limit": "500"]).map(SMSContact.init)
        var result = SMSScanResult(limited: contacts.count >= 500)
        for contact in contacts where contact.deviceID == settings.deviceID && !contact.peer.isEmpty {
            let thread = try await scanMessages(contact, matches: VerificationSMS.containsCode)
            result.items.append(contentsOf: thread.items)
            result.limited = result.limited || thread.limited
        }
        result.items.sort { SMSMessage.orderedBefore($1.message, $0.message) }
        return result
    }
    func scanMessages(_ contact: SMSContact, matches: (SMSMessage) -> Bool) async throws -> SMSScanResult {
        var result = SMSScanResult()
        var seen = Set<String>()
        var query = ["device_id": contact.deviceID, "imsi": contact.imsi, "peer": contact.peer,
                     "limit": "500", "order": "timeline"]
        var cursors = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await rows("sms/thread", query: query)
            for row in page {
                if let sim = row["imsi"] as? String, !sim.isEmpty, !contact.imsi.isEmpty, sim != contact.imsi { continue }
                if let device = row["device_id"] as? String, !device.isEmpty, device != contact.deviceID { continue }
                if let peer = row["peer"] as? String, peer != contact.peer { continue }
                let message = SMSMessage(row)
                let item = SMSItem(contact: contact, message: message)
                if Int64(message.id) != nil, matches(message), seen.insert(item.id).inserted {
                    result.items.append(item)
                }
            }
            guard page.count == 500 else { break }
            guard let row = page.first else { break }
            let first = SMSMessage(row)
            let timelineCursor = (row["timeline_cursor"] as? NSNumber)?.stringValue
            let position = timelineCursor ?? first.originalTimestamp
            guard !position.isEmpty, Int64(first.id) != nil, cursors.insert(position + "|" + first.id).inserted else {
                result.limited = true; break
            }
            query[timelineCursor == nil ? "before_ts" : "before_timeline"] = position
            query["before_id"] = first.id
        }
        return result
    }
    func deleteMessage(_ item: SMSItem) async throws {
        guard item.contact.deviceID == settings.deviceID, !item.contact.peer.isEmpty,
              let id = Int64(item.message.id), id != 0 else { throw PhoneError.message("无法确定要删除的信息。") }
        _ = try await request("sms/messages/\(id)", query: ["device_id": item.contact.deviceID,
            "imsi": item.contact.imsi, "peer": item.contact.peer], method: "DELETE", allowMissing: true)
    }
}

struct SMSDeletion: Identifiable {
    let id = UUID()
    let items: [SMSItem]
    let scope: String
}
