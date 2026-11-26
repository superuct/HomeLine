import XCTest
import UserNotifications
@testable import HomeLine

@MainActor
final class NotificationNavigationTests: XCTestCase {
    func testColdLaunchWaitsForActiveAuthenticatedUI() throws {
        let navigation = NotificationNavigation()
        navigation.receive(["open": "sms"])
        XCTAssertNil(navigation.ready(authenticated: false, active: true))
        XCTAssertNil(navigation.ready(authenticated: true, active: false))
        let request = try XCTUnwrap(navigation.ready(authenticated: true, active: true))
        XCTAssertEqual(request.destination, .messages)
        navigation.complete(request.id)
        XCTAssertNil(navigation.pending)
    }

    func testRepeatedTapsCreateNewRequestsAndOldCompletionCannotEraseNewTap() throws {
        let navigation = NotificationNavigation()
        navigation.receive(["open": "sms"])
        let first = try XCTUnwrap(navigation.pending)
        navigation.receive(["open": "sms"])
        let second = try XCTUnwrap(navigation.pending)
        XCTAssertNotEqual(first.id, second.id)
        navigation.complete(first.id)
        XCTAssertEqual(navigation.pending, second)
    }

    func testDismissAndUnknownPayloadDoNotOpenInboxOrAnswerCalls() {
        let navigation = NotificationNavigation()
        navigation.receive(["open": "sms"], action: UNNotificationDismissActionIdentifier)
        navigation.receive(["uuid": UUID().uuidString, "caller": "10000"])
        XCTAssertNil(navigation.pending)
        navigation.receive(["open": "calls"])
        XCTAssertEqual(navigation.pending?.destination, .calls)
    }

    func testNotificationPreservesSenderAndSIMScope() throws {
        let navigation = NotificationNavigation()
        navigation.receive(["open": "sms", "sender": " +86 13812345678 ", "device_id": "ec20", "imsi": "sim-a"])
        let request = try XCTUnwrap(navigation.pending)
        let contacts = [SMSContact(["peer": "13812345678", "device_id": "ec20", "imsi": "sim-a"]),
                        SMSContact(["peer": "13812345678", "device_id": "ec20", "imsi": "sim-b"]),
                        SMSContact(["peer": "13812345678", "device_id": "other", "imsi": "sim-a"])]
        XCTAssertEqual(request.matchingContact(in: contacts, currentDeviceID: "ec20")?.imsi, "sim-a")
        XCTAssertNil(request.matchingContact(in: contacts, currentDeviceID: "other"))
    }

    func testAmbiguousSIMAndAlphanumericSenderAreNotGuessed() {
        let request = NotificationNavigation.Request(destination: .messages, sender: "13812345678")
        let contacts = [SMSContact(["peer": "13812345678", "imsi": "a"]), SMSContact(["peer": "13812345678", "imsi": "b"])]
        XCTAssertNil(request.matchingContact(in: contacts, currentDeviceID: "ec20"))
        let bank = NotificationNavigation.Request(destination: .messages, sender: "Bank106")
        XCTAssertNil(bank.matchingContact(in: [SMSContact(["peer": "106"])], currentDeviceID: "ec20"))
        XCTAssertEqual(bank.matchingContact(in: [SMSContact(["peer": "Bank106"])], currentDeviceID: "ec20")?.peer, "Bank106")
    }

    func testCallReplyOpensExistingThreadOrAllowsNewMessage() {
        let navigation = NotificationNavigation()
        navigation.reply(to: "+86 138-1234-5678")
        XCTAssertEqual(navigation.pending?.sender, "+8613812345678")
        XCTAssertEqual(navigation.pending?.composeIfMissing, true)
    }
}
