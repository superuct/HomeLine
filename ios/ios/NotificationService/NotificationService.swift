import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var completion: ((UNNotificationContent) -> Void)?
    private var best: UNNotificationContent?
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        completion = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); completion = nil; return
        }
        if let sender = content.userInfo["sender"] as? String {
            content.title = ContactNames.name(for: sender) ?? sender
        }
        if VerificationCode.isSMS(content.userInfo), VerificationCode.extract(from: content.body) != nil {
            content.categoryIdentifier = VerificationCode.category
        }
        if let count = SMSBadgeStore.receive(content.userInfo) { content.badge = NSNumber(value: count) }
        best = content
        contentHandler(content); completion = nil
    }
    override func serviceExtensionTimeWillExpire() {
        if let best { completion?(best) }
        completion = nil
    }
}
