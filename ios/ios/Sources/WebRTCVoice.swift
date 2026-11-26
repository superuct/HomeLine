import AVFoundation
import Foundation
import WebRTC

// Only one call is allowed per device. CallKit owns AVAudioSession activation.
@MainActor
final class WebRTCVoice: NSObject, RTCPeerConnectionDelegate {
    private static let audioDevice = HLWebRTCAudioDevice.shared
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audioDevice)
    }()
    private let api: NASClient
    private let id: UUID
    private var peer: RTCPeerConnection?
    private var localAudio: RTCAudioTrack?

    init(api: NASClient, id: UUID) {
        self.api = api; self.id = id
    }

    private var path: String { "homeline/rtc/calls/" + id.uuidString.lowercased() }

    static func prepareAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        audioDevice.setCallMicrophoneMuted(false)
        audioDevice.setCallHeld(false)
    }

    static func setAudioActive(_ active: Bool) {
        audioDevice.setCallAudioActive(active)
    }

    #if DEBUG
    static func setFixtureMicrophoneEnabled(_ enabled: Bool) {
        audioDevice.setFixtureMicrophoneEnabled(enabled)
    }
    #endif

    func negotiate(phone: String?) async throws {
        let factory = Self.factory
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw PhoneError.message("无法创建 WebRTC 音频连接")
        }
        peer = pc
        let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "homeline-mic")
        localAudio = track
        guard pc.add(track, streamIds: ["homeline"]) != nil else {
            throw PhoneError.message("无法加入麦克风音轨")
        }
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? PhoneError.message("无法生成 WebRTC 会话")) }
            }
        }
        try await setDescription(offer, local: true, on: pc)
        let deadline = ContinuousClock.now + .seconds(4)
        while pc.iceGatheringState != .complete {
            guard ContinuousClock.now < deadline else { throw PhoneError.message("WebRTC 地址收集超时") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let local = pc.localDescription else { throw PhoneError.message("WebRTC 地址不可用") }
        var body = ["sdp": local.sdp]
        if let phone { body["phone"] = phone }
        let raw = try await api.request(path + "/offer", body: body, timeout: 8) as? [String: Any]
        guard raw?["type"] as? String == "answer", let answer = raw?["sdp"] as? String else {
            throw PhoneError.message("NAS 没有返回 WebRTC 应答")
        }
        try await setDescription(RTCSessionDescription(type: .answer, sdp: answer), local: false, on: pc)
        let iceDeadline = ContinuousClock.now + .seconds(9)
        while pc.connectionState != .connected {
            guard pc.connectionState != .failed, pc.connectionState != .closed,
                  ContinuousClock.now < iceDeadline else { throw PhoneError.message("WebRTC 音频连接失败") }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The iPhone and NAS can transition to connected on different ticks.
        for attempt in 0..<4 {
            do {
                _ = try await api.request(path + "/connect", body: [:], timeout: 5)
                return
            } catch {
                guard attempt < 3, error.localizedDescription.contains("HTTP 409") else { throw error }
                try await Task.sleep(for: .milliseconds(175))
            }
        }
    }

    private func setDescription(_ sdp: RTCSessionDescription, local: Bool, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if local { pc.setLocalDescription(sdp, completionHandler: done) }
            else { pc.setRemoteDescription(sdp, completionHandler: done) }
        }
    }

    func status() async throws -> (state: String, codec: String?) {
        let result = try await api.request(path, timeout: 4) as? [String: Any]
        guard let state = result?["state"] as? String else { throw PhoneError.message("无法读取通话状态") }
        return (state, result?["codec"] as? String)
    }

    func state() async throws -> String { try await status().state }

    func end() async throws {
        _ = try await api.request(path + "/end", body: [:], timeout: 4)
    }

    func sendDigit(_ digit: String) async throws {
        _ = try await api.request(path + "/digit", body: ["digit": digit], timeout: 4)
    }

    func setMuted(_ muted: Bool) {
        Self.audioDevice.setCallMicrophoneMuted(muted)
        localAudio?.isEnabled = !muted
    }
    func setHeld(_ held: Bool) { Self.audioDevice.setCallHeld(held) }
    func close() { peer?.close(); peer = nil; localAudio = nil }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
