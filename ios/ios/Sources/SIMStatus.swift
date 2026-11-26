import Foundation

struct SIMSnapshot {
    let present: Bool?
    let controlOnline: Bool?
    let healthy: Bool?
    let registered: Bool?
    let registration: String
    let operatorName: String
    let network: String
    let signal: Int?
    let dataEnabled: Bool?
    let dataConnected: Bool?

    init(_ row: [String: Any]) {
        let modem = row["modem"] as? [String: Any] ?? [:]
        present = row["physical_present"] as? Bool
        controlOnline = row["control_online"] as? Bool
        healthy = row["healthy"] as? Bool
        registered = row["radio_registered"] as? Bool
        registration = row["registration_state_label"] as? String ?? ""
        operatorName = (modem["operator"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未知"
        network = (modem["network_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未知"
        let raw = modem["signal_dbm"] as? Int
        signal = raw.flatMap { (-125 ... -1).contains($0) ? $0 : nil }
        dataEnabled = row["network_enabled"] as? Bool
        dataConnected = row["data_connected"] as? Bool
    }
    var online: Bool { present == true && controlOnline == true && registered == true }
    var title: String {
        if present == false { return "模块未连接" }
        if controlOnline == false { return "模块连接中断" }
        if online { return "SIM 卡已注册网络" }
        return registrationText
    }
    var registrationText: String {
        if registered == true { return "已注册" }
        switch registration.lowercased() {
        case "denied": return "注册被拒绝"
        case "searching": return "正在搜索网络"
        case "not_registered", "unregistered": return "未注册网络"
        default: return registered == false ? "未注册网络" : "注册状态未知"
        }
    }
}

struct SIMStatusState {
    private(set) var snapshot: SIMSnapshot?
    private(set) var checkedAt: Date?
    private(set) var error: String?
    private var origin = ""
    private var deviceID = ""
    func matches(origin: String, deviceID: String) -> Bool { self.origin == origin && self.deviceID == deviceID }
    func isFresh(at now: Date) -> Bool {
        guard error == nil, let checkedAt else { return false }
        return (0...30).contains(now.timeIntervalSince(checkedAt))
    }
    mutating func received(_ row: [String: Any]?, origin: String, deviceID: String, at date: Date = Date()) {
        self.origin = origin; self.deviceID = deviceID
        snapshot = row.map(SIMSnapshot.init); checkedAt = date; error = nil
    }
    mutating func failed(_ message: String, origin: String, deviceID: String) {
        if !matches(origin: origin, deviceID: deviceID) { self = SIMStatusState() }
        self.origin = origin; self.deviceID = deviceID; error = message
    }
}
