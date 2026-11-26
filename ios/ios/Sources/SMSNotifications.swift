import BackgroundTasks
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SMSArrival: Equatable {
    let newest: Int64
    let changedThreads: Int

    init(contacts: [SMSContact], after previous: Int64?) {
        let ids = contacts.compactMap(\.latestNotifiableID)
        newest = max(previous ?? 0, ids.max() ?? 0)
        changedThreads = previous.map { baseline in ids.filter { $0 > baseline }.count } ?? 0
    }
}

@MainActor
final class SMSNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SMSNotifications()
    static let taskID = (Bundle.main.bundleIdentifier ?? "org.example.homeline") + ".inbox-refresh"
    static let autoCopyKey = "sms-auto-copy-verification-code"
    private nonisolated static let callAlertThread = "homeline.incoming-calls"
    private static let codeLifetime: TimeInterval = 5 * 60
    @Published private(set) var permissionSummary = ""
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var requestedBadgeUpgrade = false
    private var requestingPermission = false
    private var lastAutoCopy: (scope: String, id: Int64, date: Date)?
    private var pendingCopy: (content: UNNotificationContent, deadline: Date)?

    override init() {
        super.init()
        center.delegate = self
        let copy = UNNotificationAction(identifier: VerificationCode.copyAction, title: "复制验证码",
                                        options: [.foreground, .authenticationRequired])
        center.setNotificationCategories([UNNotificationCategory(identifier: VerificationCode.category,
            actions: [copy], intentIdentifiers: [], options: [])])
        NotificationCenter.default.addObserver(self, selector: #selector(copyAfterActivation),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        Task { await checkPermission() }
    }

    static func copyCode(_ code: String, expires: Date? = nil) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: code]],
            options: [.localOnly: true, .expirationDate: expires ?? Date().addingTimeInterval(codeLifetime)])
    }

    private func currentSMS(_ content: UNNotificationContent) -> Bool {
        let model = PhoneModel.shared
        let info = content.userInfo
        guard model.authenticated, VerificationCode.isSMS(info),
              let sender = info["sender"] as? String, !sender.isEmpty,
              info["device_id"] as? String == model.settings.deviceID else { return false }
        if let scope = info["reading_scope"] as? String { return scope == model.readingScope }
        guard model.settings.unified == true,
              let installation = RemotePush.storedInstallation(for: model.settings.apiURL) else { return false }
        return RemotePush.matchesInstallation(info["installation"], registered: installation)
    }

    private func autoCopy(_ notification: UNNotification) {
        let content = notification.request.content
        let now = Date()
        let expires = notification.date.addingTimeInterval(Self.codeLifetime)
        let value = content.userInfo["message_id"]
        guard defaults.bool(forKey: Self.autoCopyKey), UIApplication.shared.applicationState == .active,
              expires > now, currentSMS(content),
              content.categoryIdentifier == VerificationCode.category,
              let id = (value as? NSNumber).flatMap({ Int64($0.stringValue) }) ?? (value as? String).flatMap({ Int64($0) }), id > 0,
              let code = VerificationCode.extract(from: content.body) else { return }
        let scope = PhoneModel.shared.smsScope
        if let last = lastAutoCopy, last.scope == scope, now.timeIntervalSince(last.date) < Self.codeLifetime,
           id <= last.id { return }
        Self.copyCode(code, expires: expires)
        lastAutoCopy = (scope, id, now)
    }

    private func requestCopy(_ content: UNNotificationContent) {
        guard currentSMS(content), content.categoryIdentifier == VerificationCode.category else { return }
        pendingCopy = (content, Date().addingTimeInterval(30))
        copyAfterActivation()
    }

    @objc private func copyAfterActivation() {
        guard UIApplication.shared.applicationState == .active, let request = pendingCopy else { return }
        pendingCopy = nil
        guard request.deadline > Date(), currentSMS(request.content),
              let code = VerificationCode.extract(from: request.content.body) else { return }
        Self.copyCode(code)
    }
    func checkPermission() async {
        var settings = await center.notificationSettings()
        if !requestedBadgeUpgrade, settings.authorizationStatus == .authorized, settings.badgeSetting != .enabled {
            requestedBadgeUpgrade = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        let status = settings.authorizationStatus
        if status == .denied { permissionSummary = "系统通知权限已关闭" }
        else if settings.badgeSetting == .disabled && status != .notDetermined { permissionSummary = "主屏幕角标已关闭，请在系统通知设置中打开「标记」。" }
        else if settings.alertSetting == .disabled { permissionSummary = "系统横幅提醒已关闭" }
        else if settings.notificationCenterSetting == .disabled { permissionSummary = "通知中心显示已关闭" }
        else if settings.soundSetting == .disabled { permissionSummary = "系统通知声音已关闭" }
        else { permissionSummary = "" }
        #if DEBUG
        let delivered = await center.deliveredNotifications()
        let values: [String: Any] = ["authorization":status.rawValue, "alert":settings.alertSetting.rawValue,
            "sound":settings.soundSetting.rawValue, "lockScreen":settings.lockScreenSetting.rawValue, "badge":settings.badgeSetting.rawValue,
            "notificationCenter":settings.notificationCenterSetting.rawValue,
            "scheduledDelivery":settings.scheduledDeliverySetting.rawValue,
            "deliveredCount":delivered.count, "enabled":status == .authorized,
            "badgeSnapshotReady": SMSBadgeStore.hasStoredInbox,
            "alertStyle":settings.alertStyle.rawValue,
            "delivered":delivered.map { ["date":ISO8601DateFormatter().string(from:$0.date),
                "test":$0.request.content.title.contains("通知测试") || $0.request.content.body.contains("通路测试"),
                "remote":$0.request.trigger is UNPushNotificationTrigger] },
            "updatedAt":ISO8601DateFormatter().string(from: Date())]
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: directory.appendingPathComponent("notification-status.json"), options:.atomic)
        }
        #endif
    }
    func requestPermissionIfNeeded() async {
        guard !requestingPermission, PhoneModel.shared.authenticated,
              UIApplication.shared.applicationState == .active else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, PhoneModel.shared.authenticated {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        schedule()
        await checkPermission()
    }
    func signOut() {
        resetBadge()
        removeDelivered { VerificationCode.isSMS($0.userInfo) }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
    }
    func resetBadge() {
        SMSBadgeStore.reset()
        center.setBadgeCount(0, withCompletionHandler: nil)
    }
    func updateBadge(_ count: Int) {
        center.setBadgeCount(count, withCompletionHandler: nil)
    }
    private func removeDelivered(_ matches: @escaping (UNNotificationContent) -> Bool) {
        Task {
            let notifications = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: notifications.filter {
                matches($0.request.content)
            }.map { $0.request.identifier })
        }
    }
    func postIncomingCall(id: UUID, caller: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "随行电话来电"
        content.body = ContactNames.callLabel(caller) ?? caller
        content.sound = .default
        content.threadIdentifier = Self.callAlertThread
        content.userInfo = ["open": "call"]
        center.add(UNNotificationRequest(identifier: Self.callAlertID(id), content: content, trigger: nil),
                   withCompletionHandler: nil)
    }
    func clearIncomingCall(id: UUID) {
        let identifier = Self.callAlertID(id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    private static func callAlertID(_ id: UUID) -> String { callAlertThread + "." + id.uuidString }
    func schedule() {
        guard PhoneModel.shared.authenticated else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    private func key(_ scope: String) -> String { "sms-notification-cursor." + scope }

    func observe(_ contacts: [SMSContact], scope: String, unreadCount: Int) async {
        guard PhoneModel.shared.authenticated, PhoneModel.shared.smsScope == scope, !Task.isCancelled else { return }
        let cursorKey = key(scope)
        let previous = (defaults.object(forKey: cursorKey) as? NSNumber)?.int64Value
        let arrival = SMSArrival(contacts: contacts, after: previous)
        if arrival.changedThreads > 0 {
            let content = UNMutableNotificationContent()
            let latest = contacts.filter { ($0.latestNotifiableID ?? 0) > (previous ?? 0) }.sorted(by: SMSContact.newestFirst).first
            content.title = latest.map { ContactNames.name(for: $0.peer) ?? $0.peer } ?? "新信息"
            content.body = latest?.preview ?? "收到新信息"
            content.threadIdentifier = latest?.peer ?? "sms"
            content.sound = .default
            content.badge = NSNumber(value: unreadCount)
            content.userInfo = ["open": "sms"]
            if let latest {
                content.userInfo["sender"] = latest.peer
                content.userInfo["device_id"] = latest.deviceID
                content.userInfo["imsi"] = latest.imsi
                if let id = latest.latestNotifiableID { content.userInfo["message_id"] = id }
                content.userInfo["reading_scope"] = scope.components(separatedBy: "|").dropLast().joined(separator: "|")
                if let id = latest.latestNotifiableID, Int64(latest.lastMessageID) == id,
                   VerificationCode.extract(from: content.body) != nil {
                    content.categoryIdentifier = VerificationCode.category
                }
            }
            // Each delivery needs its own ID so clearing an older read notice
            // cannot remove a newer notice that arrived during reconciliation.
            do { try await center.add(UNNotificationRequest(identifier: "homeline-inbox-" + UUID().uuidString, content: content, trigger: nil)) }
            catch { return }
        }
        if PhoneModel.shared.authenticated, PhoneModel.shared.smsScope == scope, previous != arrival.newest {
            defaults.set(arrival.newest, forKey: cursorKey)
        }
    }

    func clearRead(_ receipts: [SMSReadReceipt], scope: String, installation: String?, stillCurrent: @MainActor () -> Bool) async {
        let delivered = await center.deliveredNotifications()
        guard stillCurrent() else { return }
        let identifiers = delivered.filter {
            SMSNotificationReadState.isRead(userInfo: $0.request.content.userInfo, deliveredAt: $0.date,
                                            receipts: receipts, scope: scope, installation: installation)
        }.map { $0.request.identifier }
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.threadIdentifier == Self.callAlertThread { return [] }
        if await PhoneModel.shared.notificationIsAlreadyRead(notification.request.content.userInfo) { return [] }
        await autoCopy(notification)
        return notification.request.content.badge == nil ? [.banner, .sound, .list] : [.banner, .sound, .list, .badge]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == VerificationCode.copyAction {
            await requestCopy(response.notification.request.content)
            return
        }
        await NotificationNavigation.shared.receive(response.notification.request.content.userInfo, action: response.actionIdentifier)
    }
}

struct SMSNotificationSettings: View {
    @ObservedObject private var alerts = SMSNotifications.shared
    @AppStorage(SMSNotifications.autoCopyKey) private var autoCopy = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section {
            Toggle("前台自动复制验证码", isOn: $autoCopy)
            if !alerts.permissionSummary.isEmpty {
                Text(alerts.permissionSummary).foregroundStyle(.secondary)
                Link("打开系统通知设置", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
            }
        } header: { Text("通知") } footer: {
            Text("Apple Watch 通过系统通知镜像收到来电提醒。收到验证码时，可以长按通知选择「复制验证码」。")
        }.task { await alerts.checkPermission() }
         .onChange(of: phase) { _, new in if new == .active { Task { await alerts.checkPermission() } } }
    }
}
