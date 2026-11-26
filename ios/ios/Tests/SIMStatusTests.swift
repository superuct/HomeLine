import XCTest
@testable import HomeLine

final class SIMStatusTests: XCTestCase {
    private let sample: [String: Any] = ["physical_present": true, "control_online": true, "radio_registered": true,
        "network_enabled": false, "modem": ["operator": "中国电信", "network_mode": "LTE", "signal_dbm": -92]]
    func testCellularRegistrationDoesNotRequireMobileData() {
        let card = SIMSnapshot(sample)
        XCTAssertTrue(card.online)
        XCTAssertEqual(card.dataEnabled, false)
        XCTAssertEqual(card.signal, -92)
    }
    func testDisconnectedModuleOverridesCachedRegistration() {
        var row = sample; row["physical_present"] = false
        let card = SIMSnapshot(row)
        XCTAssertFalse(card.online)
        XCTAssertEqual(card.title, "模块未连接")
    }
    func testMissingFieldsAndUnknownSignalAreNotInvented() {
        let card = SIMSnapshot(["modem": ["signal_dbm": -128]])
        XCTAssertNil(card.signal)
        XCTAssertNil(card.dataEnabled)
        XCTAssertFalse(card.online)
        XCTAssertEqual(card.registrationText, "注册状态未知")
    }
    func testErrorImmediatelyInvalidatesOnlineStatusAndRetainsLastSample() {
        var state = SIMStatusState(); let now = Date()
        state.received(sample, origin: "nas", deviceID: "ec20", at: now)
        XCTAssertTrue(state.isFresh(at: now))
        state.failed("连接失败", origin: "nas", deviceID: "ec20")
        XCTAssertFalse(state.isFresh(at: now))
        XCTAssertNotNil(state.snapshot)
    }
    func testAgeScopeAndMissingDevice() {
        var state = SIMStatusState(); let now = Date()
        state.received(sample, origin: "nas", deviceID: "ec20", at: now)
        XCTAssertFalse(state.isFresh(at: now.addingTimeInterval(31)))
        XCTAssertFalse(state.matches(origin: "another", deviceID: "ec20"))
        state.failed("连接失败", origin: "another", deviceID: "ec20")
        XCTAssertNil(state.snapshot)
        state.received(nil, origin: "nas", deviceID: "ec20", at: now)
        XCTAssertTrue(state.isFresh(at: now))
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.error)
    }
}
