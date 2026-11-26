import XCTest
@testable import HomeLine

final class SMSBadgeTests: XCTestCase {
    private let installation = UUID()

    private func arrival(_ id: Int64, sender: String, owner: UUID? = nil) throws -> SMSBadgeStore.Arrival {
        try XCTUnwrap(SMSBadgeStore.Arrival(["open": "sms", "installation": (owner ?? installation).uuidString,
                                            "device_id": "ec20", "imsi": "sim", "sender": sender, "message_id": id]))
    }

    func testPushesCountUnreadConversationsWhileAppIsClosed() throws {
        let first = try arrival(41, sender: "+8613800138000")
        let repeatSender = try arrival(42, sender: "13800138000")
        let second = try arrival(43, sender: "10000")
        let retiredGateway = try arrival(44, sender: "10001", owner: UUID())
        let inbox = SMSBadgeStore.Inbox(installation: installation, device: "ec20", through: 40,
                                        unread: [first.thread: 39])
        XCTAssertEqual(inbox.count(with: [first, repeatSender, second, second, retiredGateway]), 2)
        XCTAssertNil(SMSBadgeStore.Arrival(["open": "call", "message_id": 45]))
    }

    func testReadingClearsOnlyMessagesSeenAndIgnoresLatePushes() throws {
        let first = try arrival(41, sender: "10000")
        let newer = try arrival(42, sender: "10000")
        let covered = try arrival(40, sender: "10001")
        var inbox = SMSBadgeStore.Inbox(installation: installation, device: "ec20", through: 40,
                                        unread: [first.thread: 39])
        inbox.markRead(thread: first.thread, through: 41)
        XCTAssertEqual(inbox.count(with: [first, covered]), 0)
        XCTAssertEqual(inbox.count(with: [first, newer]), 1)
        inbox.markRead(thread: first.thread, through: 42)
        XCTAssertEqual(inbox.count(with: [first, newer]), 0)
    }
}
