import Foundation
import Combine
import CallKit
import AVFoundation

struct CallRecord: Codable, Identifiable {
    var id: UUID
    var number: String
    var incoming: Bool
    var date: Date
    var connected: Bool
    var hasRecording: Bool? = nil
    var connectedAt: Date? = nil
    var endedAt: Date? = nil
    var duration: TimeInterval? {
        guard connected, let connectedAt, let endedAt, endedAt >= connectedAt else { return nil }
        return endedAt.timeIntervalSince(connectedAt)
    }
    var durationText: String? {
        guard let duration else { return nil }
        let total = Int(duration)
        if total >= 3600 { return "\(total / 3600)小时\(total / 60 % 60)分\(total % 60)秒" }
        if total >= 60 { return "\(total / 60)分\(total % 60)秒" }
        return "\(total)秒"
    }
    var recordingURL: URL? { hasRecording == true ? VoiceService.recordingURL(id) : nil }
}

final class VoiceService: NSObject, ObservableObject, CXProviderDelegate {
    @Published var status = "电话未连接" { didSet { writeDiagnosticStatus() } }
    @Published var registered = false
    @Published var activeNumber = ""
    @Published var inCall = false
    @Published var muted = false
    @Published var codec = ""
    @Published var lastCallError: String?
    @Published var connectedAt: Date?
    @Published var ringing = false
    @Published var speakerEnabled = false
    @Published private var requestedOutputID: String?
    private let outputQueue = DispatchQueue(label: "org.example.homeline.audio-route")
    private var outputWork: DispatchWorkItem?
    @Published private(set) var onHold = false
    @Published private(set) var mediaReady = false
    @Published private(set) var recording = false
    @Published private(set) var recordingSaved = false
    @Published var controlError: String?
    private var recordingPath: URL?
    static func recordingURL(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecordings", isDirectory: true).appendingPathComponent(id.uuidString + ".wav")
    }
    private static func prepareRecordingDirectory(for url: URL) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    func startRecording() {
        guard mediaReady, !onHold, !recording, !recordingSaved else { return }
        if rtcCall != nil, let id = activeID {
            let url = Self.recordingURL(id)
            do {
                try Self.prepareRecordingDirectory(for: url)
                try HLWebRTCAudioDevice.shared.callRecorder.start(at: url)
                recording = true
            } catch {
                controlError = "无法开始录音：" + error.localizedDescription
            }
            return
        }
    }
    func stopRecording() {
        guard recording else { return }
        if rtcCall != nil {
            recording = false
            do {
                try HLWebRTCAudioDevice.shared.callRecorder.finish()
                recordingSaved = true
            } catch {
                controlError = "未能保存有效的录音文件：" + error.localizedDescription
            }
            return
        }
    }
    func deleteRecording(for id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }), let url = history[index].recordingURL else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            history[index].hasRecording = false
            saveHistory()
        } catch { lastCallError = "删除录音失败：" + error.localizedDescription }
    }
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "call-history") }
    }
    @Published var history: [CallRecord] = []
    private var provider: CXProvider
    private var controller = CXCallController()
    private var callKitRecoveryCount = 0
    private var settings = ConnectionSettings()
    private var session = CallSession()
    private var activeID: UUID? { session.id }
    private var rtcAPI: NASClient?
    private var rtcCall: WebRTCVoice?
    private var rtcWork: Task<Void, Never>?
    private var rtcWatcher: Task<Void, Never>?
    var supportsHold: Bool {
        #if DEBUG
        if previewingCall { return true }
        #endif
        return rtcAPI != nil
    }
    private var recentPushCalls: [UUID: Date] = [:]
    var isIncoming: Bool { incoming }
    private var hasActiveSIPCall: Bool {
        false
    }
    private func clearReceiveMetrics() {
    }
    private var incoming = false
    private var connected = false
    private var endingLocally = false
    private var callStarted = Date()

    #if DEBUG
    private var previewingCall = false
    func prepareCallPreview(ringing: Bool) {
        guard ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1" else { return }
        previewingCall = true
        registered = true; activeNumber = "10000"; inCall = true
        self.ringing = ringing; mediaReady = !ringing
        connectedAt = ringing ? nil : Date().addingTimeInterval(-83)
        status = ringing ? "来电" : "通话中"
    }
    #endif

    private func writeDiagnosticStatus() {
        #if DEBUG
        var value: [String: Any] = ["registered": registered, "inCall": inCall, "codec": codec,
                                  "status": status, "lastCallError": lastCallError ?? "", "updatedAt": ISO8601DateFormatter().string(from: Date())]
        value["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        value["callKitRecoveryCount"] = callKitRecoveryCount
        value["voiceClarityEnabled"] = true
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("voice-status.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        #endif
    }

    private static func makeProvider() -> CXProvider {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.includesCallsInRecents = false
        return CXProvider(configuration: configuration)
    }

    override init() {
        provider = Self.makeProvider()
        super.init()
        provider.setDelegate(self, queue: .main)
        if let data = UserDefaults.standard.data(forKey: "call-history") {
            history = (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
        }
    }

    private func rebuildCallKit() {
        let previous = provider
        previous.setDelegate(nil, queue: nil)
        provider = Self.makeProvider()
        controller = CXCallController()
        provider.setDelegate(self, queue: .main)
        previous.invalidate()
        callKitRecoveryCount += 1
        writeDiagnosticStatus()
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = components.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || parts[0] == 127
    }

    @MainActor
    func connectWebRTC(api: NASClient) throws {
        guard !inCall else { throw PhoneError.message("请先结束当前通话") }
        disconnect()
        rtcAPI = api
        status = "正在连接电话…"
        refreshWebRTC()
    }

    @MainActor
    private func refreshWebRTC() {
        guard let api = rtcAPI, !inCall else { return }
        Task { @MainActor in
            let reply = try? await api.request("homeline/rtc/capabilities", timeout: 5) as? [String: Any]
            guard self.rtcAPI === api, !self.inCall else { return }
            self.registered = reply?["transport"] as? String == "webrtc"
            self.status = self.registered ? "电话已连接" : "WebRTC 电话连接失败"
        }
    }

    @MainActor
    private func watchWebRTC(_ call: WebRTCVoice, id: UUID) {
        rtcWatcher?.cancel()
        rtcWatcher = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled, let self, self.activeID == id, self.rtcCall === call {
                do {
                    let update = try await call.status()
                    let state = update.state
                    guard !Task.isCancelled, self.activeID == id else { return }
                    failures = 0
                    switch state {
                    case "ended":
                        self.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
                        self.finishCall(); return
                    case "active":
                        self.ringing = false; self.mediaReady = true; self.codec = update.codec ?? "WebRTC"
                        if !self.connected {
                            self.connected = true; self.connectedAt = Date()
                            if !self.incoming { self.provider.reportOutgoingCall(with: id, connectedAt: self.connectedAt) }
                        }
                        self.status = self.onHold ? "已保持" : "通话中"
                    case "alerting": self.status = "对方正在响铃…"
                    case "dialing": self.status = "正在呼叫…"
                    default: break
                    }
                } catch {
                    if Task.isCancelled || self.activeID != id { return }
                    failures += 1
                    if failures == 3 {
                        self.lastCallError = "与 NAS 的通话连接已中断。"
                        self.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
                        self.finishCall(); return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            }
        }
    }

    @MainActor
    private func startWebRTC(id: UUID, phone: String?, action: CXAction) async {
        guard let api = rtcAPI, activeID == id else { action.fail(); return }
        let call = rtcCall ?? WebRTCVoice(api: api, id: id)
        rtcCall = call
        do {
            guard await AVAudioApplication.requestRecordPermission(), activeID == id else {
                throw PhoneError.message("请允许使用麦克风")
            }
            try WebRTCVoice.prepareAudio()
            if let phone {
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .phoneNumber, value: phone)
                update.localizedCallerName = ContactNames.callLabel(phone)
                update.supportsHolding = supportsHold; update.supportsDTMF = true
                provider.reportCall(with: id, updated: update)
                provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
            }
            status = "正在连接通话…"
            try await call.negotiate(phone: phone)
            guard !Task.isCancelled, activeID == id, rtcCall === call else {
                action.fail(); return
            }
            action.fulfill()
            ringing = false
            watchWebRTC(call, id: id)
        } catch {
            action.fail()
            guard !Task.isCancelled, activeID == id, !endingLocally else { return }
            lastCallError = error.localizedDescription
            provider.reportCall(with: id, endedAt: Date(), reason: .failed)
            finishCall()
            Task { @MainActor in try? await call.end() }
        }
    }

    func disconnect() {
        if let id = activeID { provider.reportCall(with: id, endedAt: Date(), reason: .failed); finishCall() }
        rtcAPI = nil; registered = false; status = "电话未连接"
    }
    var hasCore: Bool {
        rtcAPI != nil
    }
    func foreground() {
        if rtcAPI != nil { Task { @MainActor in self.refreshWebRTC() } }
    }
    func background() {
    }

    @MainActor
    func dial(_ number: String) async {
        guard registered else { lastCallError = "电话账号尚未连接，请检查网络后在设置中重新连接。"; return }
        guard !inCall else { return }
        guard number.range(of: "^[0-9]{2,20}$", options: .regularExpression) != nil else { lastCallError = "请输入 2 至 20 位数字号码"; return }
        guard await AVAudioApplication.requestRecordPermission() else { lastCallError = "请在系统设置中允许麦克风"; return }
        guard registered, !inCall else { return }
        let id = UUID()
        controlError = nil; session.begin(id: id); clearReceiveMetrics(); lastCallError = nil; activeNumber = number; inCall = true; incoming = false; connected = false; callStarted = Date()
        do {
            try await CallKitStartRequest.perform(isCurrent: { self.activeID == id && !self.hasActiveSIPCall && self.rtcCall == nil }, request: {
                let action = CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: number))
                try await self.controller.request(CXTransaction(action: action))
            }, recover: { self.rebuildCallKit() })
        } catch {
            guard activeID == id else { return }
            let failure = error as NSError
            if failure.domain == CXErrorDomainRequestTransaction,
               failure.code == CXErrorCodeRequestTransactionError.unknownCallProvider.rawValue {
                lastCallError = "系统电话服务暂不可用，请稍后再拨。此次呼叫尚未发到 NAS。"
            } else { lastCallError = "系统无法发起通话：\(error.localizedDescription)" }
            finishCall()
        }
    }
    func hangup() {
        guard let id = activeID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            if error != nil { DispatchQueue.main.async {
                guard let self, self.activeID == id else { return }
                self.endingLocally = true
                if let call = self.rtcCall { Task { @MainActor in try? await call.end() } }
                self.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
                if self.activeID == id { self.finishCall() }
            } }
        }
    }
    func toggleMute() {
        guard let id = activeID else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: !muted))) { _ in }
    }
    var audioOutputs: [(id: String, label: String, icon: String)] {
        #if DEBUG
        if previewingCall { return [("default", "iPhone", "iphone"), ("speaker", "扬声器", "speaker.wave.3.fill")] }
        #endif
        if rtcAPI != nil {
            let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
            let external = inputs.filter { $0.portType != .builtInMic }
            return [("default", "iPhone", "iphone"), ("speaker", "扬声器", "speaker.wave.3.fill")] +
                external.map { ($0.uid, $0.portName, $0.portType == .carAudio ? "car" : "headphones") }
        }
        return []
    }
    var outputID: String? {
        #if DEBUG
        if previewingCall { return speakerEnabled ? "speaker" : "default" }
        #endif
        return requestedOutputID ?? Self.currentAudioOutputID
    }
    private static var currentAudioOutputID: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        if route.outputs.contains(where: { $0.portType == .builtInSpeaker }) { return "speaker" }
        return route.inputs.first(where: { $0.portType != .builtInMic })?.uid ?? "default"
    }
    func refreshAudioRoute() {
        guard rtcAPI != nil else { return }
        let actual = Self.currentAudioOutputID
        if let requested = requestedOutputID {
            guard actual == requested, outputWork == nil else { return }
            requestedOutputID = nil
        }
        speakerEnabled = actual == "speaker"
    }
    func selectOutput(_ id: String) {
        #if DEBUG
        if previewingCall {
            speakerEnabled = id == "speaker"
            return
        }
        #endif
        if rtcAPI != nil {
            guard let callID = activeID, requestedOutputID == nil, id != outputID else { return }
            controlError = nil
            requestedOutputID = id
            speakerEnabled = id == "speaker"
            let work = DispatchWorkItem { [weak self] in
                let error: String?
                do { try Self.applyAudioOutput(id); error = nil }
                catch let failure { error = failure.localizedDescription }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeID == callID, self.requestedOutputID == id else { return }
                    self.outputWork = nil
                    if let error {
                        self.controlError = error
                        self.requestedOutputID = nil
                    }
                    self.refreshAudioRoute()
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                        guard let self, self.activeID == callID, self.requestedOutputID == id,
                              self.outputWork == nil else { return }
                        self.requestedOutputID = nil
                        self.refreshAudioRoute()
                    }
                }
            }
            outputWork = work
            outputQueue.asyncAfter(deadline: .now() + .milliseconds(35), execute: work)
            return
        }
    }
    private static func applyAudioOutput(_ id: String) throws {
        let session = AVAudioSession.sharedInstance()
        if id == "speaker" {
            try session.overrideOutputAudioPort(.speaker)
            return
        }
        let input = (session.availableInputs ?? []).first {
            id == "default" ? $0.portType == .builtInMic : $0.uid == id
        }
        guard id == "default" || input != nil else { throw PhoneError.message("所选音频设备已断开") }
        if currentAudioOutputID == "speaker" { try session.overrideOutputAudioPort(.none) }
        if let input, session.preferredInput?.uid != input.uid,
           session.currentRoute.inputs.first?.uid != input.uid || session.preferredInput != nil {
            try session.setPreferredInput(input)
        }
    }
    func toggleHold() {
        #if DEBUG
        if previewingCall, mediaReady { onHold.toggle(); return }
        #endif
        guard let id = activeID, supportsHold, mediaReady || onHold else { return }
        controlError = nil
        controller.request(CXTransaction(action: CXSetHeldCallAction(call: id, onHold: !onHold))) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.controlError = error.localizedDescription } }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard provider === self.provider, activeID == action.callUUID else { action.fail(); return }
        if let call = rtcCall {
            Task { @MainActor in
                guard self.rtcCall === call, self.activeID == action.callUUID,
                      !self.endingLocally, self.mediaReady || self.onHold else { action.fail(); return }
                if action.isOnHold { self.stopRecording() }
                call.setHeld(action.isOnHold)
                self.onHold = action.isOnHold
                self.status = action.isOnHold ? "已保持" : "通话中"
                action.fulfill()
            }
            return
        }
        action.fail()
    }
    func sendDTMF(_ digit: String) {
        guard mediaReady, !onHold, digit.count == 1, "0123456789*#".contains(digit) else { return }
        if let call = rtcCall {
            Task { @MainActor in
                do { try await call.sendDigit(digit) } catch { self.controlError = error.localizedDescription }
            }
            return
        }
    }
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard provider === self.provider, activeID == action.callUUID, mediaReady else { action.fail(); return }
        if let rtcCall {
            Task { @MainActor in
                do {
                    for digit in action.digits { try await rtcCall.sendDigit(String(digit)) }
                    action.fulfill()
                } catch { action.fail() }
            }
            return
        }
        action.fail()
    }

    func answer() {
        guard let id = activeID, ringing else { return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: id))) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.lastCallError = "无法接听：\(error.localizedDescription)" } }
        }
    }

    @MainActor
    func reportPush(id: UUID, caller: String, valid: Bool, pickup: Bool, completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: caller)
        update.localizedCallerName = ContactNames.callLabel(caller)
        update.hasVideo = false; update.supportsHolding = supportsHold
        let duplicate = recentPushCalls[id] != nil || activeID == id
        let accept = valid && rtcAPI != nil && !duplicate && activeID == nil
        if accept {
            session.begin(id: id); incoming = true; connected = false; activeNumber = caller
            inCall = true; ringing = true; callStarted = Date(); status = "来电"
        }
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            DispatchQueue.main.async {
                defer { completion() }
                guard let self else { return }
                if !accept {
                    if error == nil && self.activeID != id { self.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded) }
                    return
                }
                guard self.activeID == id else { return }
                if error != nil { self.finishCall() }
                else if self.ringing && !self.endingLocally { SMSNotifications.shared.postIncomingCall(id: id, caller: caller) }
            }
        }
        guard accept else { return }
        if let rtcAPI {
            let call = WebRTCVoice(api: rtcAPI, id: id)
            rtcCall = call
            watchWebRTC(call, id: id)
            return
        }
    }

    private func finishCall() {
        outputWork?.cancel(); outputWork = nil; requestedOutputID = nil
        rtcWork?.cancel(); rtcWork = nil
        rtcWatcher?.cancel(); rtcWatcher = nil
        stopRecording()
        let finishedRTC = rtcCall
        rtcCall = nil
        if let finishedRTC { Task { @MainActor in finishedRTC.close() } }
        recentPushCalls = recentPushCalls.filter { Date().timeIntervalSince($0.value) < 90 }
        if let id = activeID, incoming {
            recentPushCalls[id] = Date()
            if connected || endingLocally {
                Task { @MainActor in SMSNotifications.shared.clearIncomingCall(id: id) }
            }
        }
        if let id = activeID {
            history.insert(CallRecord(id: id, number: activeNumber, incoming: incoming, date: callStarted, connected: connected,
                                      hasRecording: recordingSaved, connectedAt: connectedAt, endedAt: Date()), at: 0)
            history = history.enumerated().filter { $0.offset < 100 || $0.element.hasRecording == true }.map(\.element)
            saveHistory()
        }
        if !recordingSaved, let url = recordingPath { try? FileManager.default.removeItem(at: url) }
        recordingPath = nil; recordingSaved = false; onHold = false; mediaReady = false
        session.reset(); activeNumber = ""; inCall = false; muted = false; codec = ""
        ringing = false; connectedAt = nil; endingLocally = false; speakerEnabled = false
        status = registered ? "电话已连接" : "电话未连接"
    }
    func providerDidReset(_ provider: CXProvider) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] != nil { return }
        #endif
        guard provider === self.provider else { return }
        if inCall { lastCallError = "系统电话服务已重置，当前通话已结束，请重新拨打。" }
        if let call = rtcCall { Task { @MainActor in try? await call.end() } }
        finishCall()
        rebuildCallKit()
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard provider === self.provider, action.callUUID == activeID, !hasActiveSIPCall else { action.fail(); return }
        if rtcAPI != nil {
            rtcWork = Task { @MainActor in await self.startWebRTC(id: action.callUUID, phone: action.handle.value, action: action) }
            return
        }
        action.fail()
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard provider === self.provider, action.callUUID == activeID, ringing else { action.fail(); return }
        let id = action.callUUID
        Task { @MainActor in SMSNotifications.shared.clearIncomingCall(id: id) }
        if rtcAPI != nil {
            rtcWork = Task { @MainActor in await self.startWebRTC(id: action.callUUID, phone: nil, action: action) }
            return
        }
        action.fail()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard provider === self.provider, action.callUUID == activeID else { action.fail(); return }
        if let rtcAPI {
            let id = action.callUUID
            endingLocally = true
            rtcWork?.cancel()
            rtcWatcher?.cancel()
            Task { @MainActor in
                let call = self.rtcCall ?? WebRTCVoice(api: rtcAPI, id: id)
                do {
                    try await call.end()
                    action.fulfill()
                    if self.activeID == id { self.finishCall() }
                } catch {
                    action.fail()
                    if self.activeID == id {
                        self.endingLocally = false; self.lastCallError = "挂断未确认，请重试。"
                        self.watchWebRTC(call, id: id)
                    }
                }
            }
            return
        }
        action.fail()
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard provider === self.provider, action.callUUID == activeID else { action.fail(); return }
        if let call = rtcCall {
            Task { @MainActor in call.setMuted(action.isMuted) }
        }
        muted = action.isMuted; action.fulfill()
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard provider === self.provider else { return }
        if rtcAPI != nil {
            refreshAudioRoute()
            HLWebRTCAudioDevice.shared.setCallAudioActive(true)
        }
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard provider === self.provider else { return }
        HLWebRTCAudioDevice.shared.setCallAudioActive(false)
    }
}
