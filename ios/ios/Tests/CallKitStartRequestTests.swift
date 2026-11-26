import XCTest
import CallKit
@testable import HomeLine

final class CallKitStartRequestTests: XCTestCase {
    private var missingProvider: NSError {
        NSError(domain: CXErrorDomainRequestTransaction,
                code: CXErrorCodeRequestTransactionError.unknownCallProvider.rawValue)
    }

    @MainActor func testRejectedStartRebuildsAndRetriesOnce() async throws {
        var attempts = 0, rebuilds = 0
        try await CallKitStartRequest.perform(isCurrent: { true }, request: {
            attempts += 1
            if attempts == 1 { throw self.missingProvider }
        }, recover: { rebuilds += 1 })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
    }

    @MainActor func testPersistentFailureDoesNotLoop() async {
        var attempts = 0, rebuilds = 0
        do {
            try await CallKitStartRequest.perform(isCurrent: { true }, request: {
                attempts += 1; throw self.missingProvider
            }, recover: { rebuilds += 1 })
            XCTFail("Expected the second rejection to surface")
        } catch { XCTAssertEqual((error as NSError).code, missingProvider.code) }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
    }

    @MainActor func testOtherErrorsDoNotRebuildOrRetry() async {
        for error in [NSError(domain: CXErrorDomainRequestTransaction, code: 1),
                      NSError(domain: NSURLErrorDomain, code: 2)] {
            var attempts = 0, rebuilds = 0
            do {
                try await CallKitStartRequest.perform(isCurrent: { true }, request: {
                    attempts += 1; throw error
                }, recover: { rebuilds += 1 })
                XCTFail("Expected original error")
            } catch {}
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(rebuilds, 0)
        }
    }

    @MainActor func testEndedCallCannotBeRetried() async {
        var current = true, attempts = 0
        do {
            try await CallKitStartRequest.perform(isCurrent: { current }, request: {
                attempts += 1; throw self.missingProvider
            }, recover: { current = false })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor func testAcceptedStartIsNeverReplayed() async throws {
        var attempts = 0, rebuilds = 0
        try await CallKitStartRequest.perform(isCurrent: { true }, request: {
            attempts += 1
        }, recover: { rebuilds += 1 })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(rebuilds, 0)
    }
}
