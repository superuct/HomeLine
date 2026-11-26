import XCTest
@testable import HomeLine

final class SMSActionsTests: XCTestCase {
    func testEncodedLengthAndRetryIdentity() {
        XCTAssertTrue(SMSSendAttempt.accepts(String(repeating: "字", count: 512)))
        XCTAssertFalse(SMSSendAttempt.accepts(String(repeating: "字", count: 513)))
        XCTAssertTrue(SMSSendAttempt.accepts(String(repeating: "😀", count: 256)))
        XCTAssertFalse(SMSSendAttempt.accepts(String(repeating: "😀", count: 257)))
        let first = SMSSendAttempt.reuse(nil, origin: "a", peer: "10000", body: "hello")
        XCTAssertEqual(SMSSendAttempt.reuse(first, origin: "a", peer: "10000", body: "hello").id, first.id)
        XCTAssertNotEqual(SMSSendAttempt.reuse(first, origin: "b", peer: "10000", body: "hello").id, first.id)
    }

    func testExtractsOnlyAnUnambiguousCompleteCode() {
        XCTAssertEqual(VerificationCode.extract(from: "【随行】验证码为：001234，请勿泄露。"), "001234")
        XCTAssertEqual(VerificationCode.extract(from: "a3G7h8 is your login code."), "a3G7h8")
        XCTAssertEqual(VerificationCode.extract(from: "验证码：456789（验证码 456789）"), "456789")
        for text in ["订单号 123456", "验证码 123456789", "验证码 1234-5678", "验证码 1234 5678",
                     "登录验证码 123456，支付验证码 987654", "1234 is your verification code: 5678"] {
            XCTAssertNil(VerificationCode.extract(from: text), text)
        }
        XCTAssertNil(VerificationSMS.code(in: SMSMessage(["type": 2, "content": "验证码 123456"])))
    }

    func testOnlyReceivedAuthenticationCodesAreSelected() {
        for text in ["【服务】您的验证码为：123456，请勿泄露。", "验证码【9A37】", "9081 is your login code",
                     "Your verification code is A3G7H8", "【登入】驗證碼：4321"] {
            XCTAssertTrue(VerificationSMS.containsCode(SMSMessage(["type": 1, "content": text])), text)
        }
        for text in ["取件码 123456", "订单编号 123456，验证码请勿透露", "verification code is 123456789",
                     "不要把验证码发给别人", "送货时间 12:30", "验证码为 ABCDEF"] {
            XCTAssertFalse(VerificationSMS.containsCode(SMSMessage(["type": 1, "content": text])), text)
        }
        for kind in [2, 3, 0] {
            XCTAssertFalse(VerificationSMS.containsCode(SMSMessage(["type": kind, "content": "验证码 123456"])))
        }
    }

    @MainActor
    func testInboxKeepsContactsWhenDeviceAndThreadRequestsFail() async {
        let model = PhoneModel()
        model.settings = ConnectionSettings()
        model.settings.apiURL = "https://inbox-timeout.invalid"
        model.authenticated = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SMSStub.self]
        await model.refresh(using: NASClient(settings: model.settings, token: "test", sessionConfiguration: config))
        XCTAssertTrue(model.hasLoadedInbox)
        XCTAssertEqual(model.contacts.map(\.peer), ["test-peer"])
        XCTAssertNotNil(model.refreshError)
    }

    @MainActor
    func testVerificationPrefetchSurvivesTabReentryAndScopesToServer() async throws {
        SMSStub.reset()
        let model = PhoneModel()
        model.settings.apiURL = "https://sms-actions.invalid"
        model.authenticated = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SMSStub.self]
        let api = NASClient(settings: model.settings, token: "test", sessionConfiguration: config)
        model.preloadVerification(using: api)
        for _ in 0..<200 where model.verificationLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.verificationScan?.items.count, 2)
        model.preloadVerification(using: api)
        XCTAssertFalse(model.verificationLoading)
        model.settings.apiURL = "https://another-server.invalid"
        XCTAssertNil(model.verificationScan)
    }

    func testContactMatchingKeepsDistinctNumbersSeparate() {
        XCTAssertEqual(ContactNames.key("+86 138-1234-5678"), ContactNames.key("13812345678"))
        XCTAssertEqual(ContactNames.key("0086 13812345678"), ContactNames.key("13812345678"))
        XCTAssertNotEqual(ContactNames.key("+1 2025550123"), ContactNames.key("+44 2025550123"))
    }

    func testMixedHistoryDeletesOnlyMatchedIDsAcrossPages() async throws {
        SMSStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SMSStub.self]
        var settings = ConnectionSettings()
        settings.apiURL = "https://sms-actions.invalid"
        let api = NASClient(settings: settings, token: "test", sessionConfiguration: config)
        let result = try await api.scanVerificationMessages()
        XCTAssertFalse(result.limited)
        XCTAssertEqual(Set(result.items.map { $0.message.id }), ["-8", "505"])
        for item in result.items { try await api.deleteMessage(item) }
        let contact = try XCTUnwrap(result.items.first?.contact)
        let everything = try await api.scanMessages(contact) { _ in true }
        XCTAssertTrue(everything.items.contains { $0.message.id == "504" && $0.message.outgoing })
        XCTAssertTrue(everything.items.contains { $0.message.id == "10" })
        XCTAssertFalse(everything.items.contains { ["505", "-8"].contains($0.message.id) })
        XCTAssertEqual(SMSStub.deletedIDs(), Set(["505", "-8"]))
    }
}

private final class SMSStub: URLProtocol {
    private static var deleted = Set<String>()
    private static let lock = NSLock()
    static func reset() { lock.withLock { deleted = [] } }
    static func deletedIDs() -> Set<String> { lock.withLock { deleted } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var status = 200
        var body: Any = []
        if url.host == "inbox-timeout.invalid", url.path != "/api/sms/contacts" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if url.path == "/api/sms/contacts" {
            body = [["device_id":"ec20","imsi":"test","peer":"test-peer","last_content":"普通通知"]]
        } else if url.path == "/api/sms/thread" {
            let deleted = Self.deletedIDs()
            let paged = query.contains { $0.name == "before_id" && $0.value == "10" }
            if paged {
                body = [["id": -8, "content": "验证码 7987", "type": 1, "timestamp": "1"],
                        ["id": -9, "content": "验证码 6565", "type": 1, "imsi": "another", "timestamp": "2"]]
            } else {
                body = (10..<510).map { id -> [String: Any] in
                    ["id": id, "type": id == 504 ? 2 : 1, "timestamp": String(id),
                     "content": [504, 505].contains(id) ? "验证码 123456" : "普通通知"]
                }
            }
            if let records = body as? [[String: Any]] {
                body = records.filter { row in !deleted.contains(String(row["id"] as! Int)) }
            }
        } else if request.httpMethod == "DELETE", ["/api/sms/messages/505", "/api/sms/messages/-8"].contains(url.path),
                  query.contains(URLQueryItem(name: "device_id", value: "ec20")),
                  query.contains(URLQueryItem(name: "imsi", value: "test")) {
            _ = Self.lock.withLock { Self.deleted.insert(url.lastPathComponent) }
            body = ["deleted": 1]
        } else { status = 400 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
