import XCTest

final class ConversationNavigationUITests: XCTestCase {
    func testMessagesFilterUsesCenteredSegments() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "messages"]
        app.launch()

        let filter = app.navigationBars.segmentedControls.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 8))
        XCTAssertEqual(filter.frame.midX, app.frame.midX, accuracy: 8)
        XCTAssertTrue(app.staticTexts["10690000"].exists)
        XCTAssertTrue(filter.buttons["验证码"].exists)
        filter.buttons["未读"].tap()
        XCTAssertTrue(filter.buttons["未读"].isSelected)
        XCTAssertTrue(app.staticTexts["10000"].exists)
        XCTAssertFalse(app.staticTexts["10690000"].exists)
        filter.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["10690000"].exists)
    }

    func testRecentsFilterUsesCenteredSegments() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "recents"]
        app.launch()

        let filter = app.navigationBars.segmentedControls.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 8))
        XCTAssertEqual(filter.frame.midX, app.frame.midX, accuracy: 8)
        XCTAssertTrue(app.buttons["call-record-10000"].exists)
        filter.buttons["未接来电"].tap()
        XCTAssertTrue(filter.buttons["未接来电"].isSelected)
        XCTAssertTrue(app.buttons["call-record-10010"].exists)
        XCTAssertFalse(app.buttons["call-record-10000"].exists)
        filter.buttons["所有"].tap()
        XCTAssertTrue(app.buttons["call-record-10000"].exists)
        XCTAssertTrue(app.buttons["拨号键盘"].exists)
    }

    func testActiveCallExposesHoldAndNativeAudioChoices() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "call"]
        app.launch()
        let hold = app.buttons["保持通话"]
        XCTAssertTrue(hold.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["更多"].exists)
        hold.tap()
        XCTAssertTrue(app.buttons["恢复通话"].waitForExistence(timeout: 4))
        app.buttons["恢复通话"].tap()
        app.buttons["音频"].tap()
        let speaker = app.buttons["扬声器"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["iPhone"].exists)
        speaker.tap()
        XCTAssertTrue(app.buttons["音频"].exists)
        XCTAssertEqual(app.buttons["音频"].value as? String, "扬声器")
    }

    func testSIMOverviewShowsCarrierSignalAndPushStatus() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "sim"]
        app.launch()
        let text = app.staticTexts
        XCTAssertTrue(text["SIM 卡状态"].waitForExistence(timeout: 8))
        XCTAssertTrue(text.containing(NSPredicate(format: "label CONTAINS %@", "中国电信")).firstMatch.exists)
        XCTAssertTrue(text.containing(NSPredicate(format: "label CONTAINS %@", "-92 dBm")).firstMatch.exists)
        XCTAssertTrue(app.buttons["刷新 SIM 状态"].exists)
        XCTAssertTrue(text["来电与信息推送"].exists)
        XCTAssertFalse(text["设备与连接"].exists)
        XCTAssertFalse(text["移动数据"].exists)
        app.buttons["设备详情"].tap()
        let detail = app.navigationBars["设备详情"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(text["设备与连接"].exists)
        XCTAssertTrue(text["移动数据"].exists)
        detail.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    func testNewVerificationNotificationCopiesOnlyWhenEnabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "verification-copy"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == '允许'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts["测试就绪"].waitForExistence(timeout: 6))
        let clipboard = app.staticTexts["verification-clipboard"]
        let delivered = app.staticTexts["verification-delivery"]
        func awaitLabel(_ label: String, for element: XCUIElement) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        }
        app.buttons["验证码通知"].tap()
        awaitLabel("通知 验证码：001234", for: delivered)
        XCTAssertEqual(clipboard.label, "原有内容")
        let autoCopy = app.switches["测试自动复制"]
        autoCopy.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(autoCopy.value as? String, "1")
        app.buttons["验证码通知"].tap()
        awaitLabel("001234", for: clipboard)
        app.buttons["重复验证码通知"].tap()
        awaitLabel("通知 验证码：567890", for: delivered)
        XCTAssertEqual(clipboard.label, "001234")
        app.buttons["普通通知"].tap()
        awaitLabel("通知 订单编号：987654", for: delivered)
        XCTAssertEqual(clipboard.label, "001234")

        app.buttons["延时验证码通知"].tap()
        XCUIDevice.shared.press(.home)
        let banner = springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "072349")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 8))
        banner.press(forDuration: 0.6)
        let copyAction = springboard.buttons["复制验证码"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5))
        copyAction.tap()
        awaitLabel("072349", for: clipboard)
    }

    func testReadingOnlyClearsOlderNotificationAndPreservesNewAndOtherThread() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "read-notification"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == '允许'")).firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let old = app.staticTexts["read-check-old"]
        XCTAssertTrue(old.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["read-check-new"].exists)
        XCTAssertTrue(app.staticTexts["read-check-other"].exists)
        app.buttons["读取较早信息"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: old)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["read-check-new"].exists)
        XCTAssertTrue(app.staticTexts["read-check-other"].exists)
    }

    func testNotificationOpensItsConversationAndCanReturnToInbox() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "notification-thread"]
        app.launch()
        XCTAssertTrue(app.navigationBars["10000"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["通知会话预览"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        app.navigationBars["10000"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["信息"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        app.tabBars.buttons["最近通话"].tap()
        app.tabBars.buttons["信息"].tap()
        XCTAssertTrue(app.navigationBars["信息"].exists, "通知只消费一次，切回信息页不应再次打开旧会话")
    }

    func testCallDetailSupportsLongPressCopyAndAppReply() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "call-actions"]
        app.launch()
        let row = app.buttons["call-record-10000"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // Tap the middle empty space rather than the number or info symbol.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["通话详情"].waitForExistence(timeout: 5))
        let number = app.descendants(matching: .any).matching(identifier: "copy-call-number").firstMatch
        number.press(forDuration: 0.8)
        XCTAssertTrue(number.label.contains("已复制"))
        XCTAssertTrue(app.buttons["系统电话拨打"].exists)
        XCTAssertTrue(app.buttons["系统信息回复"].exists)
        let reply = app.buttons["信息回复"]
        if !reply.isHittable { app.swipeUp() }
        reply.tap()
        XCTAssertTrue(app.navigationBars["10000"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["通知会话预览"].exists)
    }

    func testSendingKeepsKeyboardAndPreservesNextDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "message-send"]
        app.launch()

        let composer = app.descendants(matching: .any)["message-composer"].firstMatch
        let send = app.buttons["发送信息"]
        let keyboard = app.keyboards.firstMatch
        let pending = app.descendants(matching: .any)["message-sending"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("First message")
        send.tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 2))
        let sentText = app.staticTexts.matching(NSPredicate(format: "label == %@", "First message"))
        let bubbleID = sentText.firstMatch.identifier
        XCTAssertTrue(bubbleID.hasPrefix("message-bubble-"))
        XCTAssertTrue(keyboard.exists)
        XCTAssertFalse(send.isEnabled)
        app.typeText("Next draft")

        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertEqual(sentText.count, 1)
        XCTAssertEqual(sentText.firstMatch.identifier, bubbleID)
        XCTAssertFalse(pending.exists)
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(composer.value as? String, "Next draft")

        send.tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 2))
        XCTAssertTrue(keyboard.exists)
        app.typeText("Keep this")
        XCTAssertTrue(app.buttons["复制未确认的信息"].waitForExistence(timeout: 8))
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(composer.value as? String, "Keep this")
    }

    func testCancelledBackHidesTabBarAndCompletedBackRestoresIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["HOMELINE_TEST_MODE": "1", "HOMELINE_UI_PREVIEW": "message-navigation"]
        app.launch()
        let row = app.buttons["preview-conversation"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        row.tap()
        XCTAssertTrue(app.navigationBars["10000"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

        for _ in 0..<2 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            let partial = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 0.7)
            XCTAssertTrue(app.navigationBars["10000"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.isHittable, "取消返回后仍在会话页，底栏应保持隐藏")
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "完整返回列表后应恢复底栏")
    }
}
