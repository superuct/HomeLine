import XCTest
@testable import HomeLine

final class SMSTimelineTests: XCTestCase {
    func testSendKeepsOneBubbleWithSameIdentityThroughDelayedRefresh() {
        let older = SMSMessage(["id": 9, "type": 2, "content": "相同内容"])
        var timeline = SMSConversationTimeline(messages: [older])
        let draftID = timeline.begin("相同内容")
        XCTAssertEqual(timeline.rows.map(\.id), ["9", draftID])
        XCTAssertEqual(timeline.rows.last?.sendingStatus, "正在发送…")

        timeline.submit(draftID, response: ["id": 11])
        let concurrent = SMSMessage(["id": 10, "type": 2, "content": "相同内容"])
        timeline.replace(with: [older, concurrent])
        XCTAssertEqual(timeline.rows.map(\.id), ["9", "10", draftID])
        XCTAssertEqual(timeline.rows.last?.sendingStatus, "已提交")

        let confirmed = SMSMessage(["id": 11, "type": 2, "content": "相同内容"])
        timeline.replace(with: [older, concurrent, confirmed])
        XCTAssertEqual(timeline.rows.map(\.id), ["9", "10", draftID])
        XCTAssertEqual(timeline.rows.last?.message?.id, "11")
        XCTAssertNil(timeline.rows.last?.sendingStatus)
    }

    func testLegacyAcknowledgementDoesNotReuseAnOlderMatchingMessage() {
        let older = SMSMessage(["id": 9, "type": 2, "content": "相同内容"])
        var timeline = SMSConversationTimeline(messages: [older])
        let pending = timeline.begin(older.text)
        timeline.submit(pending, response: [:])
        timeline.replace(with: [older])
        XCTAssertNil(timeline.rows.last?.message)
        let confirmed = SMSMessage(["id": 10, "type": 2, "content": older.text])
        timeline.replace(with: [older, confirmed])
        XCTAssertEqual(timeline.rows.map(\.id), ["9", pending])
        XCTAssertEqual(timeline.rows.last?.message?.id, "10")
    }

    private func row(_ id: Int, original: Any, recorded: Any, outgoing: Bool = false, imported: Bool = false) -> [String: Any] {
        ["id": id, "type": outgoing ? 2 : 1, "content": outgoing ? "查询" : "回复",
         "timestamp": original, "created_at": recorded, "imported": imported]
    }
    private var sent: SMSMessage {
        SMSMessage(row(21, original: "2026-09-23T08:14:21+08:00", recorded: "2026-09-23T08:14:21.358385799+08:00", outgoing: true))
    }
    private var reply: SMSMessage {
        SMSMessage(row(22, original: "2026-09-23T08:13:22+08:00", recorded: "2026-09-23T08:14:24.23902164+08:00"))
    }
    private var contact: SMSContact {
        SMSContact(["peer": "10000", "device_id": "ec20", "imsi": "test-sim", "last_content": "回复",
                    "last_sms_id": 22, "last_timestamp": reply.originalTimestamp,
                    "updated_at": reply.recordedTimestamp, "unread_count": 1])
    }
    @MainActor
    func testOpeningThreadSurvivesRefreshAndOnlyNewIncomingShowsDot() {
        let model = PhoneModel()
        model.authenticated = true
        model.settings.username = UUID().uuidString
        let thread = contact.summarizing([sent, reply])
        XCTAssertTrue(model.isUnread(thread))
        model.markDisplayed([sent, reply], contact: thread, scope: model.readingScope)
        XCTAssertFalse(model.isUnread(thread))
        let reloaded = PhoneModel()
        reloaded.settings = model.settings
        XCTAssertFalse(reloaded.isUnread(contact), "启动时未经详情校正的服务器旧未读数不能覆盖本机已读位置")
        let outgoing = SMSMessage(row(23, original: "", recorded: "2026-09-24T00:00:00Z", outgoing: true))
        XCTAssertFalse(reloaded.isUnread(contact.summarizing([sent, reply, outgoing])))
        let newReply = SMSMessage(row(24, original: "", recorded: "2026-09-24T00:00:01Z"))
        XCTAssertTrue(reloaded.isUnread(contact.summarizing([reply, newReply])))
        reloaded.settings.username += "-other"
        XCTAssertTrue(reloaded.isUnread(thread))
    }
    @MainActor
    func testMarkAllReadWorksBeforeIncomingSummaryLoads() {
        let model = PhoneModel()
        model.authenticated = true
        model.settings.username = UUID().uuidString
        model.contacts = [contact]
        model.markInboxRead()
        let restored = PhoneModel()
        restored.settings = model.settings
        XCTAssertFalse(restored.isUnread(contact))
        XCTAssertFalse(restored.isUnread(contact.summarizing([reply])))
        let newer = SMSMessage(row(24, original: "", recorded: "2026-09-24T00:00:01Z"))
        XCTAssertTrue(restored.isUnread(contact.summarizing([reply, newer])))
    }
    @MainActor
    func testViewingOutgoingOnlyThreadAlsoPersistsReadPosition() {
        let model = PhoneModel()
        model.authenticated = true
        model.settings.username = UUID().uuidString
        var outgoingOnly = contact
        outgoingOnly.lastMessageID = sent.id
        model.markDisplayed([sent], contact: outgoingOnly, scope: model.readingScope)
        let restored = PhoneModel()
        restored.settings = model.settings
        XCTAssertFalse(restored.isUnread(outgoingOnly))
        XCTAssertTrue(restored.isUnread(contact.summarizing([sent, reply])))
    }
    @MainActor
    func testAlreadyReadNotificationCanBeRecognizedBeforeContactListLoads() {
        let model = PhoneModel()
        model.authenticated = true
        model.settings.username = UUID().uuidString
        model.markDisplayed([reply], contact: contact, scope: model.readingScope)
        let restored = PhoneModel()
        restored.settings = model.settings; restored.authenticated = true
        let payload: [AnyHashable: Any] = ["open": "sms", "sender": "10000", "device_id": "ec20", "imsi": "test-sim", "message_id": 22]
        XCTAssertTrue(restored.notificationIsAlreadyRead(payload))
        var newPayload = payload; newPayload["message_id"] = 24
        XCTAssertFalse(restored.notificationIsAlreadyRead(newPayload))
        restored.settings.username += "-other"
        XCTAssertFalse(restored.notificationIsAlreadyRead(payload))
    }
    func testReplyWithEarlierNetworkTimeFollowsSentRecord() throws {
        let messages = [reply, sent].sorted(by: SMSMessage.orderedBefore)
        XCTAssertEqual(messages.map(\.id), ["21", "22"])
        XCTAssertEqual(reply.timestamp, reply.recordedTimestamp)
        XCTAssertEqual(reply.originalTimestamp, "2026-09-23T08:13:22+08:00")
        let difference = try XCTUnwrap(reply.timelineDate).timeIntervalSince(XCTUnwrap(sent.timelineDate))
        XCTAssertEqual(difference, 2.881, accuracy: 0.01)
    }
    func testContactPreviewAndOrderingUseSameLatestMessage() {
        var source = contact
        source.preview = "旧预览"
        let summary = source.summarizing([reply, sent])
        XCTAssertEqual(summary.preview, "回复")
        XCTAssertEqual(summary.timestamp, reply.timestamp)
        XCTAssertEqual(summary.lastMessageID, reply.id)
        var other = source
        other.peer = "other"
        other.timestamp = "2026-09-23T08:14:23+08:00"
        XCTAssertEqual([other, summary].sorted(by: SMSContact.newestFirst).first?.id, summary.id)
    }
    func testImportedHistoryDoesNotMoveToImportDate() {
        let history = SMSMessage(row(-1, original: "2025-01-01T08:00:00+08:00", recorded: "2026-09-23T08:20:00+08:00", imported: true))
        XCTAssertEqual(history.timestamp, history.originalTimestamp)
        XCTAssertEqual([reply, history, sent].sorted(by: SMSMessage.orderedBefore).map(\.id), ["-1", "21", "22"])
        XCTAssertEqual(contact.summarizing([history, reply]).lastMessageID, "22")
    }
    func testSameTimeUsesNumericIDRegardlessOfResponseOrder() {
        let messages = [10, 2, 9].map { SMSMessage(row($0, original: "", recorded: "2026-09-23T00:00:00Z")) }
        XCTAssertEqual(messages.sorted(by: SMSMessage.orderedBefore).map(\.id), ["2", "9", "10"])
    }
    func testInvalidOrMissingRecordDateFallsBackToOriginal() {
        for value: Any in [NSNull(), "", "invalid"] {
            let message = SMSMessage(row(1, original: "2026-09-23T08:13:22+08:00", recorded: value))
            XCTAssertEqual(message.timestamp, message.originalTimestamp)
            XCTAssertNotNil(message.timelineDate)
        }
        let unknown = SMSMessage(row(2, original: NSNull(), recorded: "invalid"))
        XCTAssertNil(unknown.timelineDate)
        XCTAssertEqual(displayTime(unknown.timestamp), "时间未知")
    }
    func testEpochUnitsAndTimeZonesReferToSameInstant() throws {
        XCTAssertEqual(smsDate("1790122461"), smsDate("1790122461000"))
        XCTAssertEqual(try XCTUnwrap(smsDate("2026-09-23T00:14:21Z")), smsDate("2026-09-23T08:14:21+08:00"))
        XCTAssertNil(smsDate("nan"))
        XCTAssertNil(smsDate("inf"))
    }
    @MainActor
    func testATInboxShowsNewUnreadBeforeThreadIsLoaded() throws {
        let model = PhoneModel()
        model.authenticated = true
        model.settings.username = UUID().uuidString
        model.markDisplayed([reply], contact: contact, scope: model.readingScope)
        let source = SMSContact(["peer": contact.peer, "device_id": contact.deviceID, "imsi": contact.imsi,
                                 "last_sms_id": 23, "last_type": 1, "unread_count": 2,
                                 "last_timestamp": "2026-11-08 17:00:14+08:00"])
        let incoming = SMSMessage(row(23, original: source.timestamp, recorded: "2026-11-08 17:01:24.661095+08:00"))
        XCTAssertTrue(model.isUnread(source))
        var outgoing = source
        outgoing.latestIncomingID = nil
        XCTAssertFalse(model.isUnread(outgoing))
        XCTAssertEqual(try XCTUnwrap(smsDate(source.timestamp)), smsDate("2026-11-08T09:00:14Z"))
        XCTAssertEqual(try XCTUnwrap(incoming.timelineDate), smsDate("2026-11-08T09:01:24.661095Z"))
        XCTAssertEqual(source.summarizing([reply, incoming]).lastMessageID, "23")
    }
    func testCacheReusesUnchangedContactButInvalidatesNewMessage() {
        var cache = SMSSummaryCache()
        cache.store([sent, reply], for: contact)
        XCTAssertEqual(cache.summary(for: contact)?.timestamp, reply.timestamp)
        var changed = contact
        changed.lastMessageID = "23" // Same text and second can still be a new SMS.
        XCTAssertNil(cache.summary(for: changed))
        changed = contact; changed.updatedAt = "2026-09-23T08:15:00+08:00"
        XCTAssertNil(cache.summary(for: changed))
        changed = contact; changed.imsi = "another-sim"
        XCTAssertNil(cache.summary(for: changed))
        cache.retain([])
        XCTAssertNil(cache.summary(for: contact))
    }
}
