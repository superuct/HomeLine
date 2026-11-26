import Contacts
import SwiftUI

private func isCancelledRequest(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

struct RootView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var selection = 0
    @State private var navigationRevision = UUID()
    @State private var messageRequest: NotificationNavigation.Request?
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var navigation = NotificationNavigation.shared
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { RecentCallsView(voice: model.voice) }.tabItem { Label("最近通话", systemImage: "clock.fill") }.tag(0)
            NavigationStack { PhoneContactsView(voice: model.voice) }.tabItem { Label("联系人", systemImage: "person.crop.circle.fill") }.tag(1)
            NavigationStack {
                ConversationsView(openRequest: messageRequest, onOpenHandled: { id in
                    if messageRequest?.id == id { messageRequest = nil }
                })
            }.tabItem { Label("信息", systemImage: "message.fill") }.badge(model.contacts.filter(model.isUnread).count).tag(3)
            NavigationStack { SettingsView(voice: model.voice) }.tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(4)
        }
        .id("\(model.authenticated)-\(navigationRevision)")
        .modifier(CallPresentation(voice: model.voice, navigationRevision: navigationRevision))
        .task { await ContactDirectory.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await ContactDirectory.shared.refresh(); await SMSNotifications.shared.checkPermission() } }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in Task { await ContactDirectory.shared.refresh(); await SMSNotifications.shared.checkPermission() } }
        .onAppear { if !model.authenticated { selection = 4 }; openNotificationDestination() }
        .onReceive(navigation.$pending) { _ in
            // Published values are delivered before the property is updated.
            Task { @MainActor in openNotificationDestination() }
        }
        .onChange(of: phase) { _, _ in openNotificationDestination() }
        .onChange(of: model.authenticated) { _, _ in openNotificationDestination() }
        .alert("连接提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func openNotificationDestination() {
        guard let request = navigation.ready(authenticated: model.authenticated, active: phase == .active) else {
            if phase == .active, navigation.pending != nil, !model.authenticated { selection = 4 }
            return
        }
        selection = request.destination == .messages ? 3 : 0
        messageRequest = request.destination == .messages ? request : nil
        navigationRevision = request.id
        navigation.complete(request.id)
    }
}

struct ConversationsView: View {
    @EnvironmentObject var model: PhoneModel
    @ObservedObject private var directory = ContactDirectory.shared
    @State private var compose = false
    @State private var search = ""
    @State private var filter = InboxFilter.all
    @State private var deletion: SMSDeletion?
    @State private var loadingThread = false
    var openRequest: NotificationNavigation.Request? = nil
    var onOpenHandled: (UUID) -> Void = { _ in }
    @State private var openedContact: SMSContact?
    @State private var openingRequest = false
    @State private var replyRecipient = ""
    @State private var handledOpenRequest: UUID?
    private var filteredContacts: [SMSContact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let unread = model.contacts.filter(model.isUnread)
        let contacts = filter == .unread ? unread : unread + model.contacts.filter { !model.isUnread($0) }
        return query.isEmpty ? contacts : contacts.filter {
            directory.name(for: $0.peer)?.localizedCaseInsensitiveContains(query) == true
                || $0.peer.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if filter == .codes {
                VerificationInbox(search: search).id(model.smsScope)
            } else {
                List {
                    if openingRequest { ProgressView("正在打开会话…") }
                    if loadingThread || model.deletingSMS { ProgressView("正在处理信息…") }
                    if let issue = model.refreshError {
                        Label(issue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.contacts.isEmpty {
                        if !model.authenticated {
                            ContentUnavailableView("连接你的 SIM 卡", systemImage: "message", description: Text("先在设置中连接 NAS。"))
                        } else if model.hasLoadedInbox {
                            ContentUnavailableView("还没有信息会话", systemImage: "message", description: Text("下拉刷新，或点击右上角新建信息。"))
                        } else if model.refreshing {
                            ProgressView("正在读取信息会话…")
                        } else if model.refreshError == nil {
                            Text("下拉刷新以读取信息会话。").foregroundStyle(.secondary)
                        }
                    }
                    if !model.contacts.isEmpty && filteredContacts.isEmpty {
                        ContentUnavailableView(filter == .unread ? "没有匹配的未读会话" : "没有匹配的会话", systemImage: "message")
                    }
                    ForEach(filteredContacts) { contact in
                        NavigationLink {
                            ConversationView(contact: contact)
                        } label: {
                            HStack(spacing: 12) {
                                Circle().fill(model.isUnread(contact) ? Color.blue : .clear).frame(width: 8, height: 8)
                                ContactAvatar(size: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(directory.name(for: contact.peer) ?? contact.peer).font(.headline).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(conversationDate(contact.timestamp)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(contact.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.vertical, 7)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { Task { await prepareThreadDeletion(contact) } }
                                label: { Label("删除", systemImage: "trash") }
                                .disabled(loadingThread || model.deletingSMS)
                        }
                    }
                }.refreshable { await model.refresh() }
            }
        }
        .smsDeleteDialog($deletion) { snapshot in
            if let issue = await model.deleteMessages(snapshot.items, scope: snapshot.scope) { model.error = issue }
        }
        .listStyle(.plain)
        .navigationTitle("信息")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: "搜索姓名、号码或最近信息")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("全部已读", systemImage: "envelope.open") { model.markInboxRead() }
                    .accessibilityLabel("全部标为已读").disabled(!model.contacts.contains(where: model.isUnread))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { replyRecipient = ""; compose = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("新信息").disabled(!model.authenticated)
            }
            ToolbarItem(placement: .principal) {
                NativeListFilter(title: "信息筛选", selection: $filter)
            }
        }
        .sheet(isPresented: $compose) { NavigationStack { ComposeView(recipient: replyRecipient) } }
        .navigationDestination(item: $openedContact) { contact in ConversationView(contact: contact) }
        .task(id: openRequest?.id) { await openRequestedConversation() }
    }
    private func openRequestedConversation() async {
        guard let request = openRequest, request.id != handledOpenRequest, request.sender != nil, model.authenticated else { return }
        let scope = model.smsScope
        let api = model.client
        openingRequest = true
        defer { openingRequest = false }
        do {
            if let contact = request.matchingContact(in: model.contacts, currentDeviceID: model.settings.deviceID) {
                finishOpening(request.id)
                openedContact = contact
                return
            }
            let rows = try await api.rows("sms/contacts", query: ["device_id": model.settings.deviceID, "limit": "200"])
            guard !Task.isCancelled, model.authenticated, model.smsScope == scope, model.client.token == api.token else { return }
            finishOpening(request.id)
            if let contact = request.matchingContact(in: rows.map(SMSContact.init), currentDeviceID: model.settings.deviceID) {
                openedContact = contact
            } else if request.composeIfMissing, let recipient = request.sender {
                replyRecipient = recipient; compose = true
            } else {
                model.error = "未找到这条信息对应的会话，可能已被删除。你可以在信息列表中查找。"
            }
        } catch {
            guard !Task.isCancelled, model.smsScope == scope else { return }
            finishOpening(request.id)
            model.error = "暂时无法打开会话，请在信息列表刷新后重试。\n" + error.localizedDescription
        }
    }
    private func finishOpening(_ id: UUID) {
        handledOpenRequest = id
        onOpenHandled(id)
    }
    private func prepareThreadDeletion(_ contact: SMSContact) async {
        guard !loadingThread, !model.deletingSMS else { return }
        loadingThread = true
        defer { loadingThread = false }
        let scope = model.smsScope
        do {
            let result = try await model.client.scanMessages(contact) { _ in true }
            guard scope == model.smsScope, model.authenticated else { return }
            guard !result.limited else { throw PhoneError.message("会话未完整载入，请在会话中删除单条信息。") }
            guard !result.items.isEmpty else { throw PhoneError.message("没有可删除的信息。") }
            deletion = SMSDeletion(items: result.items, scope: scope)
        } catch { model.error = error.localizedDescription }
    }
}

struct ConversationView: View {
    @EnvironmentObject var model: PhoneModel
    @ObservedObject private var directory = ContactDirectory.shared
    let contact: SMSContact
    @State private var timeline: SMSConversationTimeline
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    private let preview: Bool
    private let previewSend: ((String) async throws -> SMSMessage)?

    init(contact: SMSContact, previewMessages: [SMSMessage]? = nil,
         previewSend: ((String) async throws -> SMSMessage)? = nil) {
        self.contact = contact
        self.previewSend = previewSend
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1",
           ["notification-thread", "call-actions"].contains(ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] ?? "") {
            preview = true
            _timeline = State(initialValue: SMSConversationTimeline(messages: [
                SMSMessage(["id": 1, "type": 1, "content": "通知会话预览", "created_at": "2026-11-05T01:00:00+08:00"])
            ]))
            return
        }
        #endif
        preview = previewMessages != nil
        _timeline = State(initialValue: SMSConversationTimeline(messages: previewMessages ?? []))
    }
    @State private var detailMessage: SMSMessage?
    @State private var deletion: SMSDeletion?
    @State private var text = ""
    @State private var sending = false
    @State private var sendAttempt: SMSSendAttempt?
    @State private var error: String?
    @State private var loadError: String?
    @State private var unconfirmedText: String?
    @State private var loadingMessages = false
    @State private var loadID: UUID?
    private var messages: [SMSMessage] { timeline.messages }
    private var sendAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88) }
    var body: some View {
        let rows = timeline.rows
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            messageRow(row)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        Color.clear.frame(height: 1).id("message-bottom")
                    }.padding()
                }.scrollDismissesKeyboard(.interactively)
                .onAppear { reader.scrollTo("message-bottom", anchor: .bottom) }
                .onChange(of: rows.last?.id) { _, _ in
                    withAnimation(sendAnimation) { reader.scrollTo("message-bottom", anchor: .bottom) }
                }
            }
        }
        .overlay {
            if loadingMessages && messages.isEmpty { ProgressView("正在读取信息…") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                if let issue = error ?? loadError {
                    MessageSendIssue(message: issue, unconfirmedText: unconfirmedText).padding(.horizontal)
                }
                MessageComposer(text: $text, sending: sending, disabled: preview && previewSend == nil) { Task { await send() } }
            }.background(.bar)
        }
        .smsDeleteDialog($deletion) { snapshot in
            let issue = await model.deleteMessages(snapshot.items, scope: snapshot.scope)
            await load()
            if let issue { error = issue }
        }
        .modifier(ConversationTabBar())
        .navigationTitle(directory.name(for: contact.peer) ?? contact.peer).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailMessage) { message in
            NavigationStack {
                Form {
                    LabeledContent("状态", value: message.status)
                    LabeledContent("会话时间", value: displayTime(message.timestamp, seconds: true))
                    if smsDate(message.recordedTimestamp) != nil {
                        LabeledContent("NAS 记录时间", value: displayTime(message.recordedTimestamp, seconds: true))
                    }
                    if smsDate(message.originalTimestamp) != nil {
                        LabeledContent("原始信息时间", value: displayTime(message.originalTimestamp, seconds: true))
                    }
                    Text(message.imported ? "这是一条历史导入信息，会话保留原始日期。" : "会话优先使用 NAS 记录时间。原始信息时间可能与 NAS 时钟存在偏差。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("信息详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { detailMessage = nil } }
            }.presentationDetents([.medium, .large])
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) { ContactAvatar(size: 30); Text(directory.name(for: contact.peer) ?? contact.peer).font(.caption.weight(.semibold)) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新会话").disabled(preview)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: model.contacts.first(where: { $0.id == contact.id })) { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    private func messageRow(_ row: SMSConversationTimeline.Row) -> some View {
        let outgoing = row.message?.outgoing ?? true
        return VStack(spacing: 8) {
            if let message = row.message, message.id == messages.first?.id || startsNewGroup(message) {
                Text(displayTime(message.timestamp)).font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            HStack {
                if outgoing { Spacer(minLength: 56) }
                VStack(alignment: .trailing, spacing: 6) {
                    Text(row.text).textSelection(.enabled)
                        .font(.body).padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(outgoing ? Color.white : Color.primary)
                        .background(outgoing ? Color.green : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("message-bubble-" + row.id)
                    if let status = row.sendingStatus {
                        Text(status).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("message-sending")
                    }
                }
                if !outgoing { Spacer(minLength: 56) }
            }
            .contextMenu {
                if let message = row.message {
                    if let code = VerificationSMS.code(in: message) {
                        Button("复制验证码", systemImage: "document.on.document") { SMSNotifications.copyCode(code) }
                    }
                    Button("信息详情", systemImage: "info.circle") { detailMessage = message }
                    Button("删除信息", systemImage: "trash", role: .destructive) {
                        deletion = SMSDeletion(items: [SMSItem(contact: contact, message: message)], scope: model.smsScope)
                    }.disabled(preview || model.deletingSMS)
                }
            }
        }
    }

    private func startsNewGroup(_ message: SMSMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index > 0,
              let current = message.timelineDate, let previous = messages[index - 1].timelineDate else { return false }
        return current.timeIntervalSince(previous) > 300
    }
    private func load() async {
        guard !preview, !sending else { return }
        let id = UUID()
        let scope = model.readingScope
        loadID = id
        loadingMessages = true
        defer { if loadID == id { loadingMessages = false } }
        do {
            let receivedBefore = Date()
            let loaded = try await model.client.messages(for: contact)
            guard !Task.isCancelled, !sending, visible, loadID == id, scope == model.readingScope else { return }
            timeline.replace(with: loaded)
            if scenePhase == .active { model.markDisplayed(loaded, contact: contact, scope: scope, receivedBefore: receivedBefore) }
            loadError = nil
        } catch {
            guard !Task.isCancelled, !isCancelledRequest(error), !sending, visible,
                  loadID == id, scope == model.readingScope else { return }
            loadError = error.localizedDescription
        }
    }
    private func send() async {
        guard !sending else { return }
        let submittedText = text
        let draft = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SMSSendAttempt.accepts(draft) else { error = SMSSendAttempt.lengthError; return }
        let attempt = SMSSendAttempt.reuse(sendAttempt, origin: model.smsScope, peer: contact.peer, body: draft)
        sendAttempt = attempt
        sending = true
        let id = withAnimation(sendAnimation) { timeline.begin(draft) }
        text = ""
        error = nil
        loadError = nil
        unconfirmedText = nil
        do {
            if let previewSend {
                let message = try await previewSend(draft)
                timeline.submit(id, response: ["id": message.id])
                timeline.replace(with: messages + [message])
                sendAttempt = nil
                sending = false
                return
            }
            let result = try await model.client.sendSMS(attempt, deviceID: contact.deviceID, imsi: contact.imsi)
            sendAttempt = nil
            timeline.submit(id, response: result)
            sending = false
            await load()
            await model.refresh()
        } catch {
            timeline.removeDraft(id)
            sending = false
            if text.isEmpty { text = submittedText }
            else { unconfirmedText = submittedText }
            self.error = isCancelledRequest(error)
                ? "发送结果未确认。请先刷新会话，再决定是否重发。"
                : "发送未确认：\(error.localizedDescription) 请先刷新会话确认结果，再决定是否重发。"
        }
    }
}

struct ComposeView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var number = ""
    @State private var text = ""
    @State private var sending = false
    @State private var sendAttempt: SMSSendAttempt?
    @State private var submitted = false
    @State private var pendingText = ""
    @State private var error: String?
    @State private var unconfirmedText: String?
    init(recipient: String = "") { _number = State(initialValue: recipient) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("收件人：").foregroundStyle(.secondary)
                TextField("电话号码", text: $number).keyboardType(.phonePad)
                    .accessibilityLabel("收件人号码")
            }.padding()
            Divider()
            Spacer()
            VStack {
                if sending {
                    MessageSendingBubble(text: pendingText, submitted: submitted)
                        .padding().transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }.animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: sending)
            if let error { MessageSendIssue(message: error, unconfirmedText: unconfirmedText).padding() }
        }
        .safeAreaInset(edge: .bottom) {
            MessageComposer(text: $text, sending: sending, disabled: number.isEmpty) { Task { await send() } }
                .background(.bar)
        }
        .navigationTitle("新信息").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(sending) }
        }
        .interactiveDismissDisabled(sending)
    }
    private func send() async {
        guard !sending else { return }
        let originalRecipient = number
        let peer = originalRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = text
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard peer.range(of: "^\\+?[0-9]{2,20}$", options: .regularExpression) != nil else { error = "请检查收件人号码。"; return }
        guard SMSSendAttempt.accepts(draft) else { error = SMSSendAttempt.lengthError; return }
        let attempt = SMSSendAttempt.reuse(sendAttempt, origin: model.smsScope, peer: peer, body: draft)
        sendAttempt = attempt
        submitted = false; error = nil; unconfirmedText = nil
        pendingText = draft; text = ""
        sending = true; defer { sending = false }
        do {
            _ = try await model.client.sendSMS(attempt, deviceID: model.settings.deviceID)
            sendAttempt = nil
            submitted = true
            await model.refresh()
            if text.isEmpty && number == originalRecipient { dismiss() }
        } catch {
            if text.isEmpty && number == originalRecipient {
                text = originalText
            } else {
                unconfirmedText = originalText
            }
            let message = "发送未确认，请先查看会话后再决定是否重发。"
            self.error = isCancelledRequest(error) ? message : message + "\n" + error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var voice: VoiceService
    @EnvironmentObject var model: PhoneModel
    @State private var password = ""
    @State private var address = ""
    @State private var legacyPassword = ""
    @ObservedObject private var push = RemotePush.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
        Form {
            SIMStatusSections(voice: voice, now: context.date)
            SMSNotificationSettings()
            if model.authenticated && model.settings.unified != true {
                Section {
                    DisclosureGroup("旧部署登录") {
                        SecureField("原信息管理密码", text: $legacyPassword)
                        Button("重新登录原服务") { Task { await model.login(password: legacyPassword, sipPassword: ""); legacyPassword = "" } }
                            .disabled(legacyPassword.isEmpty)
                    }
                }
            }
            Section("信息和电话") {
                TextField("服务地址（可含端口）", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("连接密码", text: $password)
                Button(model.busy ? "正在连接…" : "连接信息和电话") {
                    Task { await model.pair(address: address, password: password); password = "" }
                }.disabled(model.busy || password.isEmpty || address.isEmpty)
                if model.authenticated {
                    Button("退出登录", role: .destructive) {
                        Task {
                            if model.settings.unified == true { try? await push.unregister(from: model.client) }
                            model.logout()
                        }
                    }
                }
            }
            Section("电话诊断") {
                LabeledContent("电话", value: voice.status)
                if model.authenticated {
                    Button("重新连接电话") { model.connectVoice() }
                }
                Button("麦克风回声测试") { Task { await voice.dial("600") } }.disabled(!voice.registered || voice.inCall)
                Text("回声测试不拨外线，建议佩戴耳机。").font(.footnote).foregroundStyle(.secondary)
            }
        }.disabled(model.busy || voice.inCall)
        }
        .navigationTitle("设置")
        .onAppear { if address.isEmpty && model.authenticated { address = model.settings.apiURL } }
        .refreshable { await model.refreshSIMStatus() }
        .task { await model.refreshSIMStatus() }
    }
}
