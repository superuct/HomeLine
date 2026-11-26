import XCTest
@testable import HomeLine

final class ContactAlphabetTests: XCTestCase {
    func testChineseAndEnglishNamesUseAlphabeticSections() {
        for (name, letter) in [("张三", "Z"), ("李四", "L"), ("陈先生", "C"), ("Alice", "A"), ("éloise", "E"), ("Ｂob", "B")] {
            XCTAssertEqual(ContactAlphabet.section(for: ContactAlphabet.sortKey(name)), letter, name)
        }
    }
    func testNonAlphabeticNamesUseOtherSection() {
        for name in ["10086", "👨‍👩‍👧", "", "  "] {
            XCTAssertEqual(ContactAlphabet.section(for: ContactAlphabet.sortKey(name)), "#")
        }
    }
}
