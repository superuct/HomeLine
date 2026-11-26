import AVFoundation
import XCTest
@testable import HomeLine

final class WebRTCLANTests: XCTestCase {
    @MainActor
    func testNativePeerRecordsBothDirectionsOnDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HOMELINE_RUN_WEBRTC_FIXTURE"] == "1",
              let ca = env["HOMELINE_WEBRTC_FIXTURE_CA"].flatMap({ Data(base64Encoded: $0) }) else {
            throw XCTSkip("requires a loopback WebRTC test fixture")
        }
        var settings = ConnectionSettings()
        settings.apiURL = "https://127.0.0.1:18643"
        let api = NASClient(settings: settings, token: "rtc-native-fixture-token", trustedCA: ca)
        let id = UUID()
        let call = WebRTCVoice(api: api, id: id)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString + ".wav")
        let recorder = HLWebRTCAudioDevice.shared.callRecorder
        let audioSession = AVAudioSession.sharedInstance()
        try WebRTCVoice.prepareAudio()
        try audioSession.setActive(true)
        WebRTCVoice.setFixtureMicrophoneEnabled(true)
        WebRTCVoice.setAudioActive(true)
        var started = false
        defer {
            if started { try? recorder.finish() }
            call.close()
            WebRTCVoice.setAudioActive(false)
            WebRTCVoice.setFixtureMicrophoneEnabled(false)
            try? audioSession.setActive(false)
            try? FileManager.default.removeItem(at: target)
        }
        do {
            try await call.negotiate(phone: "10000")
            var status = try await call.status()
            for _ in 0..<30 where status.state != "active" {
                try await Task.sleep(for: .milliseconds(100))
                status = try await call.status()
            }
            XCTAssertEqual(status.state, "active")
            if env["HOMELINE_WEBRTC_REQUIRE_OPUS"] == "1" { XCTAssertEqual(status.codec, "opus") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

            try recorder.start(at: target)
            started = true
            try await Task.sleep(for: .milliseconds(1050))
            call.setHeld(true)
            try await Task.sleep(for: .milliseconds(1050))
            let heldState = try await call.state()
            XCTAssertEqual(heldState, "active")
            call.setHeld(false)
            try await Task.sleep(for: .milliseconds(1050))
            try await call.end()
            try recorder.finish()
            started = false

            let audio = try AVAudioFile(forReading: target)
            XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
            XCTAssertGreaterThanOrEqual(audio.length, 46_400)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            // The local test mic is 710 Hz and the simulated cellular leg is 350 Hz.
            for frequency in [350.0, 710.0] {
                func amplitude(in range: Range<Int>) -> Double {
                    var cosine = 0.0, sine = 0.0
                    for i in range {
                        let phase = Double(i) * 2 * Double.pi * frequency / 16_000
                        cosine += Double(samples[i]) * cos(phase)
                        sine += Double(samples[i]) * sin(phase)
                    }
                    return 2 * hypot(cosine, sine) / Double(range.count)
                }
                guard buffer.frameLength >= 46_400 else { return XCTFail("recording ended early") }
                XCTAssertGreaterThan(amplitude(in: 5600..<13600), 0.008, "missing audio before hold")
                XCTAssertLessThan(amplitude(in: 21600..<29600), 0.002, "audio leaked during hold")
                XCTAssertGreaterThan(amplitude(in: 38400..<46400), 0.008, "missing audio after resume")
            }
            let player = try AVAudioPlayer(contentsOf: target)
            XCTAssertGreaterThan(player.duration, 0.5)
            let ended = try await call.state()
            XCTAssertEqual(ended, "ended")
        } catch {
            try? await call.end()
            throw error
        }
    }
}
