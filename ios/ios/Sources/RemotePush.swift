import UIKit
import PushKit
import UserNotifications

struct PushDelivery {
    let lastAccepted: Date?
    let lastFailed: Date?
    let lastError: String?

    init(_ values: [String: Any]) {
        lastAccepted = (values["lastAccepted"] as? Double).map { Date(timeIntervalSince1970: $0) }
        lastFailed = (values["lastFailed"] as? Double).map { Date(timeIntervalSince1970: $0) }
        lastError = values["lastError"] as? String
    }

    var needsAttention: Bool {
        guard let lastFailed else { return false }
        return lastFailed > (lastAccepted ?? .distantPast)
    }
}

@MainActor
final class RemotePush: NSObject, PKPushRegistryDelegate, ObservableObject {
    static let shared = RemotePush()
    private var registry: PKPushRegistry?
    private var alert = ""
    private var voip = ""
    private var uploading = false
    private var lastUpload = ""
    private var refreshedAt = Date.distantPast
    private var registrationOrigin = ""
    @Published private(set) var providerReady = false
    @Published private(set) var status = "正在登记"
    @Published private(set) var delivery: [String: PushDelivery] = [:]
    private var model: PhoneModel { PhoneModel.shared }
    static func storedInstallation(for origin: String) -> String? {
        UserDefaults.standard.string(forKey: "push-installation|" + origin)
    }
    private var installation: String {
        let key = "push-installation|" + model.settings.apiURL
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
    nonisolated static func matchesInstallation(_ payloadValue: Any?, registered: String) -> Bool {
        guard let raw = payloadValue as? String, let received = UUID(uuidString: raw) else { return false }
        return received == UUID(uuidString: registered)
    }

    func start() {
        guard model.authenticated, model.settings.unified == true else { return }
        if registrationOrigin != model.settings.apiURL {
            registrationOrigin = model.settings.apiURL
            providerReady = false
            status = "正在登记"
            delivery = [:]
        }
        if registry == nil {
            let r = PKPushRegistry(queue: .main)
            registry = r; r.delegate = self; r.desiredPushTypes = [.voIP]
        }
        UIApplication.shared.registerForRemoteNotifications()
        sync()
    }
    func gotAlert(_ token: Data) { alert = Self.hex(token); sync() }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        voip = Self.hex(pushCredentials.token); sync()
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { voip = ""; sync() }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let p = payload.dictionaryPayload
        let id = (p["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let rtcPush = p["voice"] as? String == "webrtc"
        let expectedTransport = rtcPush
        let valid = model.authenticated && model.settings.unified == true
            && expectedTransport
            && Self.matchesInstallation(p["installation"], registered: installation)
        if valid {
            if !model.voice.hasCore { model.connectVoice() }
            model.voice.foreground()
        }
        model.voice.reportPush(id: id, caller: p["caller"] as? String ?? "未知号码", valid: valid, pickup: p["pickup"] as? Bool == true, completion: completion)
    }
    func unregister(from api: NASClient) async throws {
        _ = try await api.request("homeline/push", body: ["sms":"","voip":"","installation":installation,"pickup":true])
        lastUpload = ""
    }
    func receiveDelivery(_ value: Any?, origin: String) {
        guard model.settings.apiURL == origin, let values = value as? [String: [String: Any]] else { return }
        delivery = values.mapValues(PushDelivery.init)
    }
    func sync() {
        guard !uploading, model.authenticated, model.settings.unified == true else { return }
        let sms = alert
        guard !sms.isEmpty || !voip.isEmpty else { return }
        let api = model.client
        let origin = model.settings.apiURL
        let key = [origin, api.token, sms, voip].joined(separator: "|")
        guard key != lastUpload || Date().timeIntervalSince(refreshedAt) > 300 else { return }
        let owner = installation
        let voip = self.voip
        uploading = true
        Task {
            do {
                let r = try await api.request("homeline/push", body: ["sms":sms, "voip":voip, "installation":owner,"pickup":true]) as? [String:Any]
                uploading = false
                guard model.authenticated, model.settings.apiURL == origin, model.client.token == api.token else {
                    sync()
                    return
                }
                lastUpload = key; refreshedAt = Date()
                providerReady = r?["providerReady"] as? Bool == true
                receiveDelivery(r?["delivery"], origin: origin)
                if !providerReady { status = "NAS 待配置 Apple 推送证书" }
                else if voip.isEmpty { status = "等待 Apple 分配来电标识" }
                else if sms.isEmpty { status = "来电已登记，等待信息标识" }
                else { status = "已登记" }
                sync()
            } catch {
                uploading = false
                if model.authenticated, model.settings.apiURL == origin { status = "推送登记失败，稍后重试" }
            }
        }
    }
}
