import XCTest
@testable import CellBridge

final class ContactBookTests: XCTestCase {
    private func contact(_ id: String, _ name: String, _ numbers: String...) -> Contact {
        Contact(id: id, name: name, numbers: numbers.map { LabeledNumber(label: "mobile", value: $0) })
    }

    private lazy var book = ContactBook(contacts: [
        contact("1", "Çağrı Yılmaz", "+90 555 111 22 33"),
        contact("2", "Ali Veli", "0532 444 55 66", "+90 212 333 44 55"),
        contact("3", "Zeynep", "+1 415 555 0100"),
        contact("4", "_Eski Kayıt", "0555 999 88 77"),
    ])

    func testNameIsFoundWhateverTheNumberFormat() {
        XCTAssertEqual(book.name(for: "+905551112233"), "Çağrı Yılmaz")
        XCTAssertEqual(book.name(for: "0555 111 22 33"), "Çağrı Yılmaz")
        XCTAssertEqual(book.name(for: "+90 532 444 55 66"), "Ali Veli")
        XCTAssertEqual(book.name(for: "02123334455"), "Ali Veli") // a contact's second number works too
        XCTAssertNil(book.name(for: "+905559990000"))
    }

    func testNonNumericSendersNeverMatchAContact() {
        XCTAssertNil(book.name(for: "BANKA"))
        XCTAssertNil(book.name(for: ""))
    }

    func testTheFirstContactWinsWhenTwoShareANumber() {
        let shared = ContactBook(contacts: [contact("a", "Anne", "0555 111 22 33"), contact("b", "Baba", "+905551112233")])
        XCTAssertEqual(shared.name(for: "05551112233"), "Anne")
    }

    func testSearchIgnoresCaseAndAccents() {
        XCTAssertEqual(book.search("cagri").map(\.id), ["1"])
        XCTAssertEqual(book.search("ÇAĞRI").map(\.id), ["1"])
        XCTAssertEqual(book.search("veli").map(\.id), ["2"])
        XCTAssertEqual(book.search("").count, 4) // nothing typed: everyone
    }

    func testSearchByDigitsNeedsThreeOrMoreAndSkipsFormatting() {
        XCTAssertEqual(book.search("444 55").map(\.id), ["2"])
        XCTAssertEqual(book.search("+90 555").map(\.id), ["1"])
        XCTAssertTrue(book.search("55").isEmpty) // too short to mean a number, and no name contains it
    }

    func testSectionsAreAlphabeticalWithOddNamesLast() {
        let sections = book.sections(of: book.contacts)
        XCTAssertEqual(sections.map(\.letter), ["A", "C", "Z", "#"])
        XCTAssertEqual(sections.last?.contacts.map(\.id), ["4"])
    }
}
