import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationNavigation: ObservableObject {
    static let shared = NotificationNavigation()
    enum Destination: Equatable { case messages, calls }
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
        var sender: String? = nil
        var deviceID: String? = nil
        var imsi: String? = nil
        var composeIfMissing = false

        func matchingContact(in contacts: [SMSContact], currentDeviceID: String) -> SMSContact? {
            guard let sender, deviceID == nil || deviceID == currentDeviceID else { return nil }
            let key = SystemPhoneActions.number(sender).map(ContactNames.key)
            let matches = contacts.filter { contact in
                guard contact.deviceID == currentDeviceID, imsi == nil || contact.imsi == imsi else { return false }
                return contact.peer == sender || (key != nil && SystemPhoneActions.number(contact.peer).map(ContactNames.key) == key)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }
    @Published private(set) var pending: Request?

    func receive(_ userInfo: [AnyHashable: Any], action: String = UNNotificationDefaultActionIdentifier) {
        guard action == UNNotificationDefaultActionIdentifier else { return }
        switch userInfo["open"] as? String {
        case "sms", "messages":
            pending = Request(destination: .messages, sender: Self.nonempty(userInfo["sender"]),
                              deviceID: Self.nonempty(userInfo["device_id"]), imsi: Self.nonempty(userInfo["imsi"]))
        case "call", "calls": pending = Request(destination: .calls)
        default: break
        }
    }
    func reply(to number: String) {
        guard let number = SystemPhoneActions.number(number) else { return }
        pending = Request(destination: .messages, sender: number, composeIfMissing: true)
    }
    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.count > 128 ? nil : result
    }

    func ready(authenticated: Bool, active: Bool) -> Request? {
        authenticated && active ? pending : nil
    }
    func complete(_ id: UUID) {
        if pending?.id == id { pending = nil }
    }
}
