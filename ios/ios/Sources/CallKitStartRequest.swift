import CallKit
import Foundation

/// Only retry a start that CallKit rejected before it reached a provider.
/// Never redial a SIP call or replay an accepted transaction.
@MainActor
enum CallKitStartRequest {
    static func perform(isCurrent: () -> Bool,
                        request: () async throws -> Void,
                        recover: () -> Void) async throws {
        guard isCurrent() else { throw CancellationError() }
        do {
            try await request()
        } catch {
            let failure = error as NSError
            guard failure.domain == CXErrorDomainRequestTransaction,
                  failure.code == CXErrorCodeRequestTransactionError.unknownCallProvider.rawValue else { throw error }
            guard isCurrent() else { throw CancellationError() }
            recover()
            await Task.yield()
            guard isCurrent() else { throw CancellationError() }
            try await request()
        }
    }
}
