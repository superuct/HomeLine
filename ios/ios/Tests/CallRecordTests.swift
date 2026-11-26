import XCTest
@testable import HomeLine

final class CallRecordTests: XCTestCase {
    func testOldHistoryKeepsItsOriginalDateWithoutInventingCallTimes() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "number": "10000", "incoming": true,
                                                               "date": 100.0, "connected": true])
        let record = try JSONDecoder().decode(CallRecord.self, from: data)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.date, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertNil(record.connectedAt)
        XCTAssertNil(record.endedAt)
        XCTAssertNil(record.duration)
    }
    func testStoredCallDurationExcludesRingingAndSurvivesRelaunch() throws {
        let record = CallRecord(id: UUID(), number: "10000", incoming: false, date: Date(timeIntervalSince1970: 10), connected: true,
                                connectedAt: Date(timeIntervalSince1970: 40), endedAt: Date(timeIntervalSince1970: 125))
        let restored = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.duration, 85)
        XCTAssertEqual(restored.durationText, "1分25秒")
        XCTAssertEqual(restored.connectedAt, record.connectedAt)
        XCTAssertEqual(restored.endedAt, record.endedAt)
    }
    func testUnansweredAndInvalidTimesDoNotProduceDuration() {
        var record = CallRecord(id: UUID(), number: "10000", incoming: true, date: Date(), connected: false,
                                connectedAt: Date(timeIntervalSince1970: 40), endedAt: Date(timeIntervalSince1970: 125))
        XCTAssertNil(record.duration)
        record.connected = true; record.endedAt = Date(timeIntervalSince1970: 20)
        XCTAssertNil(record.duration)
    }
}
