import XCTest
@testable import HomeLine

final class SMSArrivalTests: XCTestCase {
    private func summary(_ rows: [[String: Any]]) -> SMSContact {
        SMSContact(["peer":"fixture"]).summarizing(rows.map(SMSMessage.init))
    }
    func testFirstSyncAndRepeatAreQuiet() {
        let rows = [summary([["id":7,"type":1]])]
        let baseline = SMSArrival(contacts: rows, after: nil)
        XCTAssertEqual(baseline.changedThreads, 0)
        XCTAssertEqual(baseline.newest, 7)
        XCTAssertEqual(SMSArrival(contacts: rows, after: baseline.newest).changedThreads, 0)
    }
    func testIncomingOnlyAndDeletedHistoryDoesNotRewind() {
        let row = summary([["id":8,"type":1],["id":9,"type":2],["id":10,"type":0],["id":11,"type":1,"imported":true]])
        let update = SMSArrival(contacts: [row], after: 7)
        XCTAssertEqual(update.changedThreads, 1)
        XCTAssertEqual(update.newest, 8)
        XCTAssertEqual(SMSArrival(contacts: [], after: update.newest).newest, 8)
    }
}
