#if DEBUG
import SwiftUI
import UserNotifications

// Offline visual review only. Launch with HOMELINE_TEST_MODE=1; no live API or calls.
struct NativeInterfacePreview: View {
    let screen: String
    @StateObject private var model = PhoneModel()
    private var contact: SMSContact { SMSContact(["peer": "10000", "device_id": "preview", "last_content": "您好，您查询的套餐信息已发送，请查收。", "last_timestamp": "2026-10-30T08:14:24+08:00", "unread_count": 1]) }
    private var messages: [SMSMessage] {
        [SMSMessage(["id": 1, "type": 2, "content": "查询套餐", "created_at": "2026-10-30T08:14:21+08:00"]),
         SMSMessage(["id": 2, "type": 1, "content": "您好，您查询的套餐信息已发送，请查收。", "created_at": "2026-10-30T08:14:24+08:00"]),
         SMSMessage(["id": 3, "type": 2, "content": "谢谢", "created_at": "2026-10-30T08:15:00+08:00"])]
    }
    var body: some View {
        Group {
            switch screen {
            case "sim", "settings": NavigationStack { SettingsView(voice: model.voice) }
            case "conversation": NavigationStack { ConversationView(contact: contact, previewMessages: messages) }
            case "message-send": NavigationStack {
                ConversationView(contact: contact, previewMessages: messages) { draft in
                    try await Task.sleep(for: .seconds(5))
                    if draft == "Next draft" { throw PhoneError.message("测试发送超时") }
                    return SMSMessage(["id": 4, "type": 2, "content": draft,
                                       "created_at": "2026-10-30T08:16:00+08:00"])
                }
            }
            case "messages": NavigationStack { ConversationsView() }
            case "notification", "notification-thread", "call-actions": RootView()
            case "message-motion": MessageNavigationPreview(contact: contact, messages: messages)
            case "message-navigation": MessageNavigationPreview(contact: contact, messages: messages, automatic: false)
            case "read-notification": ReadNotificationPreview()
            #if targetEnvironment(simulator)
            case "verification-copy": VerificationCopyPreview()
            #endif
            case "contacts": NavigationStack { PhoneContactsView(voice: model.voice) }
            case "sending": NavigationStack {
                VStack {
                    Spacer()
                    MessageSendingBubble(text: "您好，我稍后给您回电话。")
                    MessageComposer(text: .constant(""), sending: true) {}
                }.padding(.horizontal).navigationTitle("张三")
            }
            case "recents", "dialer-motion": NavigationStack { RecentCallsView(voice: model.voice) }
            case "call", "call-keypad", "call-ringing": ActiveCallView(voice: model.voice)
            case "call-large": ActiveCallView(voice: model.voice).dynamicTypeSize(.accessibility3)
            case "compose": NavigationStack { ComposeView() }
            default: NavigationStack { DialerView(voice: model.voice) }
            }
        }.environmentObject(model).tint(.blue)
            .onAppear {
                if screen == "sim" || screen == "settings" {
                    model.authenticated = true
                    model.settings.unified = true
                    model.simStatus.received(["physical_present": true, "control_online": true, "healthy": true,
                        "radio_registered": true, "network_enabled": false, "data_connected": false,
                        "modem": ["operator": "中国电信", "network_mode": "LTE", "signal_dbm": -92]],
                        origin: model.settings.apiURL, deviceID: model.settings.deviceID)
                }
                model.contacts = [contact, SMSContact(["peer": "10690000", "last_content": "这是一条用于界面预览的示例信息。", "last_timestamp": "2026-10-29T16:20:00+08:00"])]
                if ["notification", "notification-thread", "call-actions"].contains(screen) {
                    model.settings.deviceID = "preview"
                    model.authenticated = true
                    if screen == "notification-thread" { NotificationNavigation.shared.receive(["open": "sms", "sender": "10000"]) }
                    else { NotificationNavigation.shared.receive(["open": screen == "call-actions" ? "calls" : "sms"]) }
                }
                model.voice.status = "电话已连接"
                model.voice.registered = true
                model.voice.activeNumber = "10000"
                model.voice.history = [CallRecord(id: UUID(), number: "10000", incoming: false, date: Date().addingTimeInterval(-115), connected: true,
                                                connectedAt: Date().addingTimeInterval(-100), endedAt: Date().addingTimeInterval(-15)),
                                       CallRecord(id: UUID(), number: "10010", incoming: true, date: Date().addingTimeInterval(-3600), connected: false)]
                if ["call", "call-keypad", "call-ringing", "call-large"].contains(screen) {
                    model.voice.prepareCallPreview(ringing: screen == "call-ringing")
                }
            }
    }
}

private struct MessageNavigationPreview: View {
    let contact: SMSContact
    let messages: [SMSMessage]
    var automatic = true
    @State private var showingConversation = false
    var body: some View {
        TabView(selection: .constant(3)) {
            Text("最近通话").tabItem { Label("最近通话", systemImage: "clock.fill") }.tag(0)
            Text("联系人").tabItem { Label("联系人", systemImage: "person.crop.circle.fill") }.tag(1)
            NavigationStack {
                List {
                    Button("10000　您好，您查询的套餐信息已发送，请查收。") { showingConversation = true }
                        .accessibilityIdentifier("preview-conversation")
                }.navigationTitle("信息")
                    .navigationDestination(isPresented: $showingConversation) {
                        ConversationView(contact: contact, previewMessages: messages)
                    }
            }.tabItem { Label("信息", systemImage: "message.fill") }.tag(3)
            Text("设置").tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(4)
        }.task {
            guard automatic else { return }
            do {
                for _ in 0..<2 {
                    try await Task.sleep(for: .seconds(1))
                    showingConversation = true
                    try await Task.sleep(for: .seconds(2))
                    showingConversation = false
                    try await Task.sleep(for: .seconds(1))
                }
            } catch { return }
        }
    }
}
#if targetEnvironment(simulator)
private struct VerificationCopyPreview: View {
    @AppStorage(SMSNotifications.autoCopyKey) private var autoCopy = false
    @State private var clipboard = ""
    @State private var status = "正在准备"
    @State private var latestRequest = ""
    @State private var delivery = ""
    private let center = UNUserNotificationCenter.current()

    var body: some View {
        VStack(spacing: 20) {
            Text(status)
            Text(clipboard).accessibilityIdentifier("verification-clipboard")
            Text(delivery).accessibilityIdentifier("verification-delivery")
            Toggle("测试自动复制", isOn: $autoCopy).padding(.horizontal)
            Button("验证码通知") { send("验证码：001234", id: 21, isCode: true) }
            Button("重复验证码通知") { send("验证码：567890", id: 21, isCode: true) }
            Button("普通通知") { send("订单编号：987654", id: 22, isCode: false) }
            Button("延时验证码通知") { send("验证码：072349", id: 23, isCode: true, delay: 3) }
        }.task {
            guard ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1" else { return }
            let model = PhoneModel.shared
            model.settings.apiURL = "https://verification-copy.invalid"
            model.authenticated = true
            autoCopy = false
            SMSNotifications.copyCode("原有内容")
            do {
                guard try await center.requestAuthorization(options: [.alert]) else { status = "通知未授权"; return }
                status = "测试就绪"
                while !Task.isCancelled {
                    clipboard = UIPasteboard.general.string ?? ""
                    if !latestRequest.isEmpty,
                       await center.deliveredNotifications().contains(where: { $0.request.identifier == latestRequest }) {
                        delivery = latestRequest
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch is CancellationError {} catch { status = error.localizedDescription }
        }
    }

    private func send(_ body: String, id: Int, isCode: Bool, delay: TimeInterval = 1) {
        let model = PhoneModel.shared
        let content = UNMutableNotificationContent()
        content.title = "验证码复制测试"
        content.body = body
        content.userInfo = ["open": "sms", "sender": "10000", "device_id": model.settings.deviceID,
                            "reading_scope": model.readingScope, "message_id": id]
        if isCode { content.categoryIdentifier = VerificationCode.category }
        let request = "通知 \(body)"
        latestRequest = request
        center.removeDeliveredNotifications(withIdentifiers: [request])
        delivery = "等待通知"
        Task {
            try await center.add(UNNotificationRequest(identifier: request, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        }
    }
}
#endif

private struct ReadNotificationPreview: View {
    @StateObject private var model = PhoneModel()
    @State private var delivered: [String] = []
    @State private var failure = ""
    private let identifiers = ["read-check-old", "read-check-new", "read-check-other"]
    private var contact: SMSContact { SMSContact(["peer": "10000", "device_id": "ec20", "imsi": "preview-sim", "unread_count": 1, "last_sms_id": 1]) }
    var body: some View {
        VStack(spacing: 20) {
            Text("已读通知检查").font(.title)
            ForEach(delivered, id: \.self) { Text($0).accessibilityIdentifier($0) }
            Text(failure)
            Button("读取较早信息") {
                model.markDisplayed([SMSMessage(["id": 1, "type": 1, "content": "old"])], contact: contact, scope: model.readingScope)
            }
        }.task {
            guard ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1" else { return }
            model.settings.apiURL = "https://read-notification.invalid"
            model.settings.username = UUID().uuidString
            model.authenticated = true
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert]) else { failure = "通知权限未允许"; return }
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
                for (index, peer) in ["10000", "10000", "10001"].enumerated() {
                    let content = UNMutableNotificationContent()
                    content.title = "已读联动检查"
                    content.body = identifiers[index]
                    content.userInfo = ["open": "sms", "sender": peer, "device_id": "ec20", "imsi": "preview-sim", "message_id": index + 1]
                    try await center.add(UNNotificationRequest(identifier: identifiers[index], content: content,
                                                               trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
                }
                while !Task.isCancelled {
                    let snapshot = await center.deliveredNotifications().map { $0.request.identifier }.filter { identifiers.contains($0) }.sorted()
                    if snapshot != delivered { delivered = snapshot }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
#endif
