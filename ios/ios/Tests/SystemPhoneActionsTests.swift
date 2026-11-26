import XCTest
@testable import HomeLine

final class SystemPhoneActionsTests: XCTestCase {
    func testSystemActionsPreserveInternationalNumberWithoutMessageBody() {
        XCTAssertEqual(SystemPhoneActions.phoneURL("+86 (138) 1234-5678")?.absoluteString, "tel:+8613812345678")
        XCTAssertEqual(SystemPhoneActions.messageURL("10000")?.absoluteString, "sms:10000")
    }
    func testUnavailableNumbersAndInjectedURLDataAreRejected() {
        for value in ["未知号码", "10000?body=secret", "123&456", "12;34", "*#06#", "+1+2025550123", "", "1"] {
            XCTAssertNil(SystemPhoneActions.phoneURL(value), value)
            XCTAssertNil(SystemPhoneActions.messageURL(value), value)
        }
    }
}
