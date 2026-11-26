import XCTest
@testable import HomeLine

final class SMSNotificationReadStateTests: XCTestCase {
    func testReconnectingToSameNASReusesReadThroughAcrossRelays() {
        let first = "https://first.test:52143"
        let second = "https://second.test:28654"
        let contact = "ec20|sim-a|13812345678"
        let legacyScope = SMSReadPositions.scope(origin: first, username: "homeline", unifiedToken: nil)
        let firstScope = SMSReadPositions.scope(origin: first, username: "homeline", unifiedToken: "nas-a")
        let secondScope = SMSReadPositions.scope(origin: second, username: "homeline", unifiedToken: "nas-a")
        let otherScope = SMSReadPositions.scope(origin: second, username: "homeline", unifiedToken: "nas-b")
        var positions: [String: Int64] = [
            legacyScope + "|" + contact: 31,
            firstScope + "|" + contact: 22,
        ]
        SMSReadPositions.migrate(&positions, from: legacyScope, to: firstScope)
        XCTAssertEqual(positions[secondScope + "|" + contact], 31)
        XCTAssertNil(positions[legacyScope + "|" + contact])
        XCTAssertNil(positions[otherScope + "|" + contact])
        XCTAssertNil(positions[secondScope + "|ec20|sim-b|13812345678"])
    }

    private let boundary = Date(timeIntervalSince1970: 100)
    private var receipt: SMSReadReceipt {
        SMSReadReceipt(contact: SMSContact(["peer": "13812345678", "device_id": "ec20", "imsi": "a"]), through: 22, legacyBefore: boundary)
    }
    private func isRead(_ info: [AnyHashable: Any], at date: Date? = nil, receipts: [SMSReadReceipt]? = nil) -> Bool {
        SMSNotificationReadState.isRead(userInfo: info, deliveredAt: date ?? boundary, receipts: receipts ?? [receipt],
                                       scope: "https://nas.test|admin", installation: "9bd6f66c-5201-4d17-a8c6-fac20105cdba")
    }
    private var payload: [AnyHashable: Any] { ["open": "sms", "sender": "+86 13812345678", "message_id": 22, "device_id": "ec20", "imsi": "a"] }
    func testReadIDsClearEvenIfNotificationArrivesLateButNewerIDsRemain() {
        XCTAssertTrue(isRead(payload, at: boundary.addingTimeInterval(20)))
        var newer = payload; newer["message_id"] = 23
        XCTAssertFalse(isRead(newer, at: boundary.addingTimeInterval(-20)))
    }
    func testOtherSenderSIMDeviceAndAccountArePreserved() {
        for (key, value) in [("sender", "13912345678"), ("imsi", "b"), ("device_id", "other"),
                             ("reading_scope", "https://other.test|admin"), ("installation", UUID().uuidString)] {
            var info = payload; info[key] = value
            XCTAssertFalse(isRead(info), key)
        }
        var valid = payload; valid["installation"] = "9BD6F66C-5201-4D17-A8C6-FAC20105CDBA"
        XCTAssertTrue(isRead(valid))
    }
    func testLegacyNotificationsUseReadRequestBoundary() {
        var old = payload; old.removeValue(forKey: "message_id")
        XCTAssertTrue(isRead(old, at: boundary.addingTimeInterval(-1)))
        XCTAssertFalse(isRead(old, at: boundary.addingTimeInterval(1)))
    }
    func testUnknownAndMalformedNotificationsAreNotRemoved() {
        XCTAssertFalse(isRead(["open": "calls", "sender": "13812345678"]))
        for invalid: Any in ["bad", "23.5", -1, NSNull()] {
            var info = payload; info["message_id"] = invalid
            XCTAssertFalse(isRead(info))
        }
        var missingSender = payload; missingSender.removeValue(forKey: "sender")
        XCTAssertFalse(isRead(missingSender))
    }
    func testLegacyNotificationsDoNotGuessBetweenSIMs() {
        let other = SMSReadReceipt(contact: SMSContact(["peer": "13812345678", "imsi": "b"]), through: 50, legacyBefore: boundary)
        var old = payload; old.removeValue(forKey: "message_id"); old.removeValue(forKey: "imsi")
        XCTAssertFalse(isRead(old, receipts: [receipt, other]))
        var scoped = payload; scoped["imsi"] = "b"; scoped["message_id"] = 49
        XCTAssertTrue(isRead(scoped, receipts: [receipt, other]))
    }
}
