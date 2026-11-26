import Foundation

/// Associates CallKit's UUID with the SDK call. Late events from an ended or
/// rejected call must never finish a different, newer call.
struct CallSession {
    private(set) var id: UUID?
    private var sdkID: UInt?
    mutating func begin(id: UUID) { self.id = id; sdkID = nil }
    mutating func bind(_ key: UInt) -> Bool {
        guard id != nil, sdkID == nil || sdkID == key else { return false }
        sdkID = key
        return true
    }
    func matches(_ key: UInt) -> Bool { id != nil && sdkID == key }
    mutating func reset() { id = nil; sdkID = nil }
}
