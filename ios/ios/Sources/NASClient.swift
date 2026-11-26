import Foundation
import Combine
import Security
import UIKit

enum NASTrust {
    // Each bundled CA belongs to one host and port.
    static func relayAnchor(host: String, port: Int) -> Data? {
        let host = host.lowercased()
        guard !host.isEmpty, host.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (97...122).contains($0) }),
              let url = Bundle.main.url(forResource: "relay-\(host)-\(port)", withExtension: "cer") else { return nil }
        return try? Data(contentsOf: url)
    }
    static func evaluate(_ trust: SecTrust, host: String, ca: Data) -> Bool {
        guard let anchor = SecCertificateCreateWithData(nil, ca as CFData) else { return false }
        return SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess
            && SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess
            && SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
            && SecTrustEvaluateWithError(trust, nil)
    }
}

private final class NASSessionDelegate: NSObject, URLSessionTaskDelegate {
    let host: String
    let port: Int
    let trustedCA: Data?
    init(host: String, port: Int, trustedCA: Data?) { self.host = host; self.port = port; self.trustedCA = trustedCA }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trustedCA else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.host == host, challenge.protectionSpace.port == port,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // A paired NAS is its own scoped trust store. Retain hostname, expiry,
        // chain signatures and SSL policy validation; never accept an arbitrary leaf.
        guard NASTrust.evaluate(trust, host: host, ca: trustedCA) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class NASClient {
    let settings: ConnectionSettings
    let token: String
    private let session: URLSession

    init(settings: ConnectionSettings, token: String, trustedCA: Data? = nil,
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.settings = settings
        self.token = token
        let origin = URLComponents(string: settings.apiURL)
        let host = origin?.host ?? "", port = origin?.port ?? 443
        let delegate = NASSessionDelegate(host: host, port: port,
            trustedCA: trustedCA ?? NASTrust.relayAnchor(host: host, port: port))
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    private func authorizedRequest(_ path: String, query: [String: String] = [:], timeout: TimeInterval) throws -> URLRequest {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] != nil {
            throw PhoneError.message("界面预览不访问 NAS")
        }
        #endif
        guard var url = URLComponents(string: settings.apiURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PhoneError.message("请输入完整的 HTTPS 服务地址。")
        }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/" + path
        if !url.path.hasPrefix("/") { url.path = "/" + url.path }
        url.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let target = url.url else { throw PhoneError.message("服务地址无效") }
        var request = URLRequest(url: target)
        request.timeoutInterval = timeout
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }

    func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, method: String? = nil, allowMissing: Bool = false, timeout: TimeInterval? = nil) async throws -> Any {
        var request = try authorizedRequest(path, query: query, timeout: timeout ?? (body == nil ? 20 : 120))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let method { request.httpMethod = method }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PhoneError.message("服务器没有返回 HTTP 响应") }
        if allowMissing, request.httpMethod == "DELETE", response.statusCode == 404 { return [:] }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw PhoneError.message("登录已失效或没有权限，请在设置中重新登录。") }
            if response.statusCode == 429 { throw PhoneError.message("请求过于频繁，请稍后再试。") }
            if path == "sms/send", let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch detail["error"] as? String {
                case "voice_busy": throw PhoneError.message("电话线路正在使用，请在通话结束后重试。")
                case "sms_busy": throw PhoneError.message("NAS 正在处理另一条信息，请稍后重试。")
                case "send_uncertain": throw PhoneError.message("NAS 无法确认整条信息是否提交，已保留该请求以避免重复发送。")
                default: break
                }
            }
            throw PhoneError.message("服务请求失败（HTTP \(response.statusCode)）")
        }
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }
    func messages(for contact: SMSContact) async throws -> [SMSMessage] {
        try await rows("sms/thread", query: ["device_id": contact.deviceID, "imsi": contact.imsi,
                                            "peer": contact.peer, "limit": "500", "order": "timeline"])
            .map(SMSMessage.init).sorted(by: SMSMessage.orderedBefore)
    }
    func conversationSummaries(_ contacts: [SMSContact], cache: SMSSummaryCache) async throws -> (contacts: [SMSContact], cache: SMSSummaryCache) {
        var nextCache = cache
        nextCache.retain(contacts)
        let changed = contacts.filter { nextCache.summary(for: $0) == nil }
        // Bound the initial fan-out; unchanged contacts need no thread request.
        for start in stride(from: 0, to: changed.count, by: 4) {
            let batch = changed[start..<min(start + 4, changed.count)]
            let results = try await withThrowingTaskGroup(of: (SMSContact, [SMSMessage]).self) { group in
                for contact in batch { group.addTask { (contact, try await self.messages(for: contact)) } }
                var results: [(SMSContact, [SMSMessage])] = []
                for try await result in group { results.append(result) }
                return results
            }
            for (contact, messages) in results { nextCache.store(messages, for: contact) }
        }
        return (contacts.map { nextCache.summary(for: $0) ?? $0 }.sorted(by: SMSContact.newestFirst), nextCache)
    }
    func rows(_ path: String, query: [String: String]) async throws -> [[String: Any]] {
        let result = try await request(path, query: query)
        if let rows = result as? [[String: Any]] { return rows }
        if let object = result as? [String: Any] {
            for key in ["items", "messages", "contacts", "data"] {
                if let rows = object[key] as? [[String: Any]] { return rows }
            }
        }
        throw PhoneError.message("服务器返回了无法识别的数据格式")
    }
}

@MainActor
final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()
    @Published var settings: ConnectionSettings
    @Published private(set) var hasLoadedInbox = false
    @Published var contacts: [SMSContact] = []
    @Published var refreshError: String?
    @Published var deviceStatus = "尚未连接"
    @Published var error: String?
    @Published var busy = false
    @Published var authenticated = false
    let voice = VoiceService()
    @Published private var verificationResult: SMSScanResult?
    private var verificationResultScope = ""
    var verificationScan: SMSScanResult? {
        verificationResultScope == smsScope + "|" + token ? verificationResult : nil
    }
    @Published private(set) var verificationLoading = false
    @Published private(set) var verificationError: String?
    private var verificationKey = ""
    private var verificationTask: Task<Void, Never>?

    func preloadVerification(force: Bool = false, using currentClient: NASClient? = nil) {
        let fingerprint = contacts.map { $0.id + "|" + $0.lastMessageID + "|" + $0.updatedAt }.sorted().joined(separator: ";")
        let scope = smsScope + "|" + token
        let key = scope + "|" + String(smsRevision) + "|" + fingerprint
        guard authenticated else { verificationTask?.cancel(); verificationResult = nil; verificationKey = ""; return }
        guard force || verificationKey != key || (verificationScan == nil && !verificationLoading) else { return }
        if verificationKey != key { verificationResult = nil }
        verificationTask?.cancel()
        verificationKey = key; verificationLoading = true; verificationError = nil
        let api = currentClient ?? client
        verificationTask = Task {
            do {
                let result = try await api.scanVerificationMessages()
                guard !Task.isCancelled, self.verificationKey == key, self.smsScope + "|" + self.token == scope, self.authenticated else { return }
                self.verificationResultScope = self.smsScope + "|" + self.token
                self.verificationResult = result
            } catch {
                guard !Task.isCancelled, self.verificationKey == key else { return }
                self.verificationError = error.localizedDescription
            }
            if self.verificationKey == key { self.verificationLoading = false }
        }
    }

    private var token: String
    @Published private(set) var refreshing = false
    @Published private(set) var refreshingSIM = false
    @Published var simStatus = SIMStatusState()
    private var simRefresh: (origin: String, deviceID: String, token: String, task: Task<Void, Never>)?
    private var summaryCache = SMSSummaryCache()
    private var summaryCacheScope = ""
    private var contactsReceivedBefore = Date.distantPast
    private var contactsReceivedScope = ""
    @Published private var readThrough: [String: Int64] = {
        guard let data = UserDefaults.standard.data(forKey: "sms-read-through") else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }()
    var readingScope: String { settings.apiURL + "|" + settings.username }
    private var readPositionScope: String {
        SMSReadPositions.scope(origin: settings.apiURL, username: settings.username,
                               unifiedToken: settings.unified == true ? token : nil)
    }
    private func readPosition(for contact: SMSContact) -> Int64? {
        readThrough[readPositionScope + "|" + contact.id]
    }
    func isUnread(_ contact: SMSContact) -> Bool {
        guard let seen = readPosition(for: contact) else { return contact.unread > 0 }
        // Raw contact rows carry a stale server unread count. Once this phone
        // has a read position, wait for verified incoming IDs before showing a dot.
        guard let newest = contact.latestIncomingID else { return false }
        return newest > seen
    }
    func markDisplayed(_ messages: [SMSMessage], contact: SMSContact, scope: String, receivedBefore: Date = Date()) {
        guard authenticated, scope == readingScope,
              let newest = messages.compactMap({ Int64($0.id) }).max() else { return }
        advanceReadPositions([(contact.id, newest)])
        let through = readPosition(for: contact) ?? newest
        let receipt = SMSReadReceipt(contact: contact, through: through, legacyBefore: receivedBefore)
        updateBadgeAfterReading([receipt])
        clearReadNotifications([receipt], scope: scope)
    }
    func markInboxRead() {
        guard authenticated else { return }
        let before = contactsReceivedScope == smsScope ? contactsReceivedBefore : .distantPast
        let receipts = contacts.compactMap { contact -> SMSReadReceipt? in
            guard let newest = [contact.latestIncomingID, Int64(contact.lastMessageID)].compactMap({ $0 }).max() else { return nil }
            return SMSReadReceipt(contact: contact, through: newest, legacyBefore: before)
        }
        advanceReadPositions(receipts.map { ($0.contact.id, $0.through) })
        updateBadgeAfterReading(receipts)
        clearReadNotifications(receipts, scope: readingScope)
    }
    private func badgeInstallation() -> UUID? {
        guard settings.unified == true else { return nil }
        return RemotePush.storedInstallation(for: settings.apiURL).flatMap(UUID.init(uuidString:))
    }
    private func badgeThread(_ contact: SMSContact) -> String {
        SMSBadgeStore.thread(device: contact.deviceID, imsi: contact.imsi, peer: contact.peer)
    }
    private func updateBadgeAfterReading(_ receipts: [SMSReadReceipt]) {
        let alerts = SMSNotifications.shared
        if let installation = badgeInstallation(),
           let count = SMSBadgeStore.markRead(receipts.map { (badgeThread($0.contact), $0.through) },
                                              installation: installation, device: settings.deviceID) {
            alerts.updateBadge(count)
        } else if hasLoadedInbox {
            alerts.updateBadge(contacts.filter(isUnread).count)
        }
    }
    private func updateBadge(from rows: [SMSContact]) -> Int {
        let unread = contacts.filter(isUnread)
        let alerts = SMSNotifications.shared
        let count: Int
        if let installation = badgeInstallation() {
            var threads: [String: Int64] = [:]
            for contact in unread {
                let thread = badgeThread(contact)
                let newest = contact.latestIncomingID ?? Int64(contact.lastMessageID) ?? 0
                threads[thread] = max(threads[thread] ?? newest, newest)
            }
            let through = rows.compactMap { Int64($0.lastMessageID) }.max() ?? 0
            count = SMSBadgeStore.replaceInbox(.init(installation: installation, device: settings.deviceID,
                                                      through: through, unread: threads)) ?? unread.count
        } else {
            count = unread.count
        }
        alerts.updateBadge(count)
        return count
    }
    private func clearReadNotifications(_ receipts: [SMSReadReceipt], scope: String) {
        guard !receipts.isEmpty else { return }
        let installation = RemotePush.storedInstallation(for: settings.apiURL)
        Task { [weak self] in
            await SMSNotifications.shared.clearRead(receipts, scope: scope, installation: installation) { [weak self] in
                self?.authenticated == true && self?.readingScope == scope
            }
        }
    }
    func notificationIsAlreadyRead(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard authenticated, let sender = userInfo["sender"] as? String else { return false }
        var candidates = contacts
        if let device = userInfo["device_id"] as? String, device == settings.deviceID,
           let imsi = userInfo["imsi"] as? String, !imsi.isEmpty {
            let contact = SMSContact(["peer": sender, "device_id": device, "imsi": imsi])
            if !candidates.contains(where: { $0.id == contact.id }) { candidates.append(contact) }
        }
        let receipts = candidates.compactMap { contact -> SMSReadReceipt? in
            guard let seen = readPosition(for: contact) else { return nil }
            return SMSReadReceipt(contact: contact, through: seen, legacyBefore: .distantPast)
        }
        return SMSNotificationReadState.isRead(userInfo: userInfo, deliveredAt: Date(), receipts: receipts,
                                             scope: readingScope, installation: RemotePush.storedInstallation(for: settings.apiURL))
    }
    private func advanceReadPositions(_ positions: [(String, Int64)]) {
        var next = readThrough
        let scope = readPositionScope
        for (contactID, newest) in positions {
            let key = scope + "|" + contactID
            next[key] = max(next[key] ?? newest, newest)
        }
        saveReadPositions(next)
    }
    private func migrateReadPositions() {
        var next = readThrough
        SMSReadPositions.migrate(&next, from: readingScope, to: readPositionScope)
        saveReadPositions(next)
    }
    private func saveReadPositions(_ next: [String: Int64]) {
        guard next != readThrough else { return }
        readThrough = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: "sms-read-through") }
    }
    var client: NASClient {
        // An edited server address must never receive another server's bearer token.
        NASClient(settings: settings, token: Vault.read("api-origin") == settings.apiURL ? token : "", trustedCA: trustedCA)
    }
    private var trustedCA: Data? {
        guard Vault.read("api-ca-origin") == settings.apiURL else { return nil }
        return Data(base64Encoded: Vault.read("api-ca"))
    }
    init() {
        settings = UserDefaults.standard.data(forKey: "connection").flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) } ?? ConnectionSettings()
        token = Vault.read("api-token")
        authenticated = !token.isEmpty
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] != nil || ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            authenticated = false; token = ""; return
        }
        // Developer-only CA renewal for an already paired NAS; preserve all account credentials.
        let caUpdate = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("nas-ca-update.json")
        if FileManager.default.fileExists(atPath: caUpdate.path) {
            do {
                let values = try JSONSerialization.jsonObject(with: Data(contentsOf: caUpdate)) as? [String: String]
                guard let origin = values?["apiURL"], origin == settings.apiURL,
                      origin == Vault.read("api-origin"),
                      let host = URLComponents(string: origin)?.host, VoiceService.isPrivateIPv4(host),
                      let ca = values?["caDER"], let data = Data(base64Encoded: ca),
                      SecCertificateCreateWithData(nil, data as CFData) != nil else {
                    throw PhoneError.message("NAS 配对证书更新无效")
                }
                try Vault.write(ca, key: "api-ca")
                try Vault.write(origin, key: "api-ca-origin")
                try FileManager.default.removeItem(at: caUpdate)
            } catch { self.error = error.localizedDescription }
        }
        // Developer device provisioning is a separate file transfer, never a
        // credential bundled into the app. Production builds do not import it.
        let setup = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lan-setup.json")
        if FileManager.default.fileExists(atPath: setup.path) {
            do {
                let data = try Data(contentsOf: setup)
                let config = try JSONDecoder().decode(ConnectionSettings.self, from: data)
                guard let host = URLComponents(string: config.apiURL)?.host,
                      VoiceService.isPrivateIPv4(host), host == config.sipHost,
                      URLComponents(string: config.apiURL)?.scheme == "https" else { throw PhoneError.message("局域网测试配置无效") }
                let values = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let apiToken = values?["apiToken"] as? String,
                      let sipPassword = values?["sipPassword"] as? String else { throw PhoneError.message("测试配置缺少凭据") }
                settings = config
                if let ca = values?["caDER"] as? String, let decoded = Data(base64Encoded: ca),
                   SecCertificateCreateWithData(nil, decoded as CFData) != nil {
                    try Vault.write(ca, key: "api-ca")
                    try Vault.write(config.apiURL, key: "api-ca-origin")
                }
                try Vault.write(apiToken, key: "api-token")
                try Vault.write(settings.apiURL, key: "api-origin")
                try storeSIPPassword(sipPassword)
                try save()
                token = apiToken; authenticated = true
                try FileManager.default.removeItem(at: setup)
            } catch { self.error = error.localizedDescription }
        }
        #endif
        if authenticated, Vault.read("api-origin") == settings.apiURL { migrateReadPositions() }
        if authenticated && UIApplication.shared.applicationState != .background {
            Task { [weak self] in
                guard let self, self.authenticated else { return }
                if !self.voice.hasCore { self.connectVoice() }
                await self.refresh()
            }
        }
    }
    func save() throws {
        guard !voice.inCall else { throw PhoneError.message("请先结束当前通话再修改连接设置") }
        UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "connection")
    }
    func pair(address: String, password: String) async {
        guard !busy, !voice.inCall else { return }
        busy = true; defer { busy = false }
        do {
            let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var origin = URLComponents(string: text.contains("://") ? text : "https://"+text),
                  origin.scheme?.lowercased() == "https", let host = origin.host, !host.isEmpty,
                  origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
                  ["","/"].contains(origin.path), (1...65535).contains(origin.port ?? 443) else {
                throw PhoneError.message("请输入 HTTPS 地址，可带端口。")
            }
            origin.path = ""
            var next = ConnectionSettings()
            next.apiURL = origin.string ?? ""; next.sipHost = host; next.sipPort = String(origin.port ?? 443)
            next.sipTLS = true; next.unified = true
            let api = NASClient(settings: next, token: "", trustedCA: next.apiURL == settings.apiURL ? trustedCA : nil)
            let response = try await api.request("homeline/pair", body: ["password":password]) as? [String:Any]
            guard response?["version"] as? Int == 1, let bearer = response?["token"] as? String, !bearer.isEmpty,
                  let device = response?["device"] as? String, !device.isEmpty, let sip = response?["sipUser"] as? String else {
                throw PhoneError.message("此地址未提供随行电话统一服务。")
            }
            next.voiceTransport = response?["voiceTransport"] as? String
            next.deviceID = device; next.sipUser = sip; next.username = sip
            if authenticated, Vault.read("api-origin") == settings.apiURL { migrateReadPositions() }
            if authenticated, settings.unified == true, settings.apiURL != next.apiURL, token != bearer {
                // A retired or unreachable gateway must not prevent moving to a replacement.
                try? await RemotePush.shared.unregister(from: client)
            }
            guard !voice.inCall else { throw PhoneError.message("请先结束通话再切换服务") }
            voice.disconnect()
            if settings.apiURL != next.apiURL || settings.deviceID != next.deviceID { SMSNotifications.shared.resetBadge() }
            try Vault.write(bearer, key:"api-token"); try Vault.write(next.apiURL, key:"api-origin")
            settings = next
            try storeSIPPassword(password); try save()
            contacts = []; hasLoadedInbox = false; simStatus = SIMStatusState(); summaryCache = SMSSummaryCache()
            refreshError = nil; smsRevision += 1; refreshPending = refreshing
            token = bearer; authenticated = true
            migrateReadPositions()
            connectVoice()
            RemotePush.shared.start()
            Task { await SMSNotifications.shared.requestPermissionIfNeeded() }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func login(password: String, sipPassword: String) async {
        guard !busy else { return }
        guard !voice.inCall else { error = "请先结束当前通话再登录"; return }
        busy = true; defer { busy = false }
        do {
            let result = try await NASClient(settings: settings, token: "", trustedCA: trustedCA).request("auth/login", body: ["username": settings.username, "password": password])
            guard let value = (result as? [String: Any])?["token"] as? String, !value.isEmpty else { throw PhoneError.message("服务器没有返回登录凭据") }
            try Vault.write(value, key: "api-token")
            try Vault.write(settings.apiURL, key: "api-origin")
            if token != value { hasLoadedInbox = false; contacts = []; refreshError = nil }
            if !sipPassword.isEmpty { try storeSIPPassword(sipPassword) }
            try save()
            token = value; authenticated = true
            await refresh()
            connectVoice()
        } catch { self.error = error.localizedDescription }
    }
    func connectVoice() {
        do {
            guard settings.unified == true else { throw PhoneError.message("请连接支持 WebRTC 的随行电话服务") }
            try voice.connectWebRTC(api: client)
        }
        catch { self.error = error.localizedDescription }
    }
    private var sipOrigin: String { "\(settings.sipHost):\(settings.sipPort)/\(settings.sipUser)/\(settings.sipTLS)" }
    func storeSIPPassword(_ password: String) throws {
        guard !voice.inCall else { throw PhoneError.message("请先结束当前通话再修改电话账号") }
        try Vault.write(password, key: "sip-password")
        try Vault.write(sipOrigin, key: "sip-origin")
    }
    @Published private(set) var deletingSMS = false
    private var smsRevision = 0
    private var refreshPending = false
    var smsScope: String { readingScope + "|" + settings.deviceID }

    func deleteMessages(_ items: [SMSItem], scope: String) async -> String? {
        guard !deletingSMS, !items.isEmpty, authenticated, scope == smsScope else { return "信息列表已变化，请重新选择。" }
        let api = client
        guard !api.token.isEmpty else { return "请先重新登录。" }
        deletingSMS = true
        smsRevision += 1
        verificationTask?.cancel(); verificationKey = ""; verificationResult = nil; verificationLoading = false
        var count = 0
        var issue: String?
        do {
            for item in items {
                guard authenticated, scope == smsScope, api.token == token else { throw PhoneError.message("账号已切换") }
                try await api.deleteMessage(item)
                count += 1
            }
        } catch { issue = "已处理 " + String(count) + " / " + String(items.count) + " 条。请刷新确认剩余信息。" + error.localizedDescription }
        summaryCache = SMSSummaryCache()
        deletingSMS = false
        if refreshing { refreshPending = true } else { await refresh() }
        return issue
    }
    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] != nil { return }
        #endif
        guard Vault.read("api-origin") == settings.apiURL else { return }
        await refresh(using: client)
    }

    func refresh(using currentClient: NASClient) async {
        guard authenticated, !refreshing, !deletingSMS else { return }
        refreshing = true
        let revision = smsRevision
        defer {
            refreshing = false
            if refreshPending { refreshPending = false; Task { await refresh() } }
        }
        let requestToken = token
        let origin = settings.apiURL
        let deviceID = settings.deviceID
        let receivedBefore = Date()
        async let deviceRefresh: Void = refreshSIMStatus(using: currentClient)
        do {
            let scope = origin + "|" + requestToken + "|" + settings.deviceID
            let cache = summaryCacheScope == scope ? summaryCache : SMSSummaryCache()
            let rows = try await currentClient.rows("sms/contacts", query: ["device_id": settings.deviceID, "limit": "200"]).map(SMSContact.init)
            guard authenticated, token == requestToken, settings.apiURL == origin,
                  settings.deviceID == deviceID, revision == smsRevision else { return }
            contacts = rows.map { cache.summary(for: $0) ?? $0 }.sorted(by: SMSContact.newestFirst)
            contactsReceivedBefore = receivedBefore; contactsReceivedScope = smsScope
            hasLoadedInbox = true
            refreshError = nil
            let normalized = try await currentClient.conversationSummaries(rows, cache: cache)
            guard authenticated, token == requestToken, settings.apiURL == origin, settings.deviceID == deviceID else { return }
            guard revision == smsRevision else { return }
            summaryCache = normalized.cache; summaryCacheScope = scope
            contacts = normalized.contacts; refreshError = nil
            let unreadCount = updateBadge(from: rows)
            let readReceipts = normalized.contacts.compactMap { contact -> SMSReadReceipt? in
                guard let seen = readPosition(for: contact), let newest = contact.latestIncomingID else { return nil }
                return SMSReadReceipt(contact: contact, through: seen, legacyBefore: newest <= seen ? receivedBefore : .distantPast)
            }
            clearReadNotifications(readReceipts, scope: readingScope)
            preloadVerification(using: currentClient)
            writeDiagnosticStatus(connected: true)
            if settings.unified != true || !RemotePush.shared.providerReady {
                await SMSNotifications.shared.observe(normalized.contacts, scope: smsScope, unreadCount: unreadCount)
            }
        } catch {
            guard authenticated, token == requestToken, settings.apiURL == origin, settings.deviceID == deviceID, !Task.isCancelled else { return }
            self.refreshError = error.localizedDescription
            writeDiagnosticStatus(connected: false)
        }
        await deviceRefresh
    }

    func refreshSIMStatus() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] != nil { return }
        #endif
        guard authenticated, Vault.read("api-origin") == settings.apiURL else { return }
        await refreshSIMStatus(using: client)
    }

    private func refreshSIMStatus(using currentClient: NASClient) async {
        guard authenticated else { return }
        let origin = settings.apiURL
        let deviceID = settings.deviceID
        let requestToken = token
        if let simRefresh, simRefresh.origin == origin, simRefresh.deviceID == deviceID, simRefresh.token == requestToken {
            await simRefresh.task.value
            return
        }
        simRefresh?.task.cancel()
        refreshingSIM = true
        let task = Task {
            await refreshDevice(using: currentClient, token: requestToken, origin: origin, deviceID: deviceID)
            if !Task.isCancelled {
                simRefresh = nil
                refreshingSIM = false
            }
        }
        simRefresh = (origin, deviceID, requestToken, task)
        await task.value
    }

    private func refreshDevice(using currentClient: NASClient, token requestToken: String, origin: String, deviceID: String) async {
        do {
            let result = try await currentClient.request("devices", timeout: 8)
            guard let response = result as? [String: Any], let devices = response["devices"] as? [[String: Any]] else {
                throw PhoneError.message("服务器返回了无法识别的设备状态")
            }
            guard authenticated, token == requestToken, settings.apiURL == origin, settings.deviceID == deviceID, !Task.isCancelled else { return }
            RemotePush.shared.receiveDelivery(response["pushDelivery"], origin: origin)
            if settings.unified == true, !voice.inCall {
                let transport = response["voiceTransport"] as? String == "webrtc" ? "webrtc" : nil
                if settings.voiceTransport != transport {
                    settings.voiceTransport = transport
                    try save()
                    connectVoice()
                }
            }
            simStatus.received(devices.first { $0["id"] as? String == deviceID }, origin: origin, deviceID: deviceID)
            var label = "未发现指定设备"
            if let device = devices.first(where: { $0["id"] as? String == settings.deviceID }) {
                let modem = device["modem"] as? [String: Any] ?? [:]
                label = [modem["operator"] as? String, device["registration_state_label"] as? String].compactMap { $0 }.joined(separator: " · ")
                if label.isEmpty { label = device["running"] as? Bool == true ? "设备运行中" : "设备未运行" }
            }
            deviceStatus = label
        } catch {
            guard authenticated, token == requestToken, settings.apiURL == origin, settings.deviceID == deviceID, !Task.isCancelled else { return }
            simStatus.failed(error.localizedDescription, origin: origin, deviceID: deviceID)
            deviceStatus = "连接失败，显示上次结果"
        }
    }
    private func writeDiagnosticStatus(connected: Bool) {
        #if DEBUG
        let value: [String: Any] = ["apiConnected": connected, "conversationCount": contacts.count, "error": connected ? "" : (refreshError ?? ""),
                                  "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("api-status.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        #endif
    }
    func logout() {
        guard !voice.inCall else { error = "请先结束当前通话再退出登录"; return }
        voice.disconnect()
        SMSNotifications.shared.signOut()
        try? Vault.write("", key: "api-token"); try? Vault.write("", key: "sip-password")
        verificationTask?.cancel(); verificationKey = ""; verificationResult = nil; verificationLoading = false
        token = ""; authenticated = false; hasLoadedInbox = false; contacts = []; refreshError = nil; deviceStatus = "尚未连接"
        summaryCache = SMSSummaryCache(); summaryCacheScope = ""
        smsRevision += 1
        simRefresh?.task.cancel()
        simRefresh = nil
        refreshingSIM = false
        simStatus = SIMStatusState()
    }
}
