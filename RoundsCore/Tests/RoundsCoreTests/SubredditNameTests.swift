import XCTest
@testable import RoundsCore

final class SubredditNameTests: XCTestCase {
    func testAcceptsBareAndPrefixedNames() {
        XCTAssertEqual(try SubredditName.parse("mdphd").get(), "mdphd")
        XCTAssertEqual(try SubredditName.parse("r/medicalschool").get(), "medicalschool")
        XCTAssertEqual(try SubredditName.parse("/r/MCAT").get(), "MCAT")
        XCTAssertEqual(try SubredditName.parse("R/step1").get(), "step1")
        XCTAssertEqual(try SubredditName.parse("  r/USMLE/  ").get(), "USMLE")
    }

    func testAcceptsRedditURLs() {
        XCTAssertEqual(try SubredditName.parse("https://www.reddit.com/r/Residency/").get(), "Residency")
        XCTAssertEqual(try SubredditName.parse("https://old.reddit.com/r/premed/top/?t=month").get(), "premed")
        XCTAssertEqual(try SubredditName.parse("reddit.com/r/medicine").get(), "medicine")
        XCTAssertEqual(try SubredditName.parse("http://reddit.com/r/mdphd/comments/abc/title").get(), "mdphd")
    }

    func testRejectsNonSubredditURLs() {
        XCTAssertEqual(SubredditName.parse("https://www.reddit.com/user/someone"), .failure(.notASubredditURL))
        XCTAssertEqual(SubredditName.parse("https://example.com/r/mdphd"), .failure(.notASubredditURL))
    }

    func testLengthAndCharacterRules() {
        XCTAssertEqual(SubredditName.parse(""), .failure(.empty))
        XCTAssertEqual(SubredditName.parse("r/"), .failure(.empty))
        XCTAssertEqual(SubredditName.parse("ab"), .failure(.tooShort))
        XCTAssertEqual(try SubredditName.parse("abc").get(), "abc")
        XCTAssertEqual(try SubredditName.parse(String(repeating: "a", count: 21)).get().count, 21)
        XCTAssertEqual(SubredditName.parse(String(repeating: "a", count: 22)), .failure(.tooLong))
        XCTAssertEqual(SubredditName.parse("med school"), .failure(.invalidCharacters))
        XCTAssertEqual(SubredditName.parse("med-school"), .failure(.invalidCharacters))
        XCTAssertEqual(SubredditName.parse("médecine"), .failure(.invalidCharacters))
        XCTAssertEqual(try SubredditName.parse("med_school_2").get(), "med_school_2")
    }

    func testDuplicatesAreCaseInsensitive() {
        let existing = ["mdphd", "MedicalSchool"]
        XCTAssertTrue(SubredditName.isDuplicate("MDPHD", in: existing))
        XCTAssertTrue(SubredditName.isDuplicate("medicalschool", in: existing))
        XCTAssertFalse(SubredditName.isDuplicate("premed", in: existing))
        XCTAssertEqual(SubredditName.parseNew("r/MedicalSchool", existing: existing), .failure(.duplicate("MedicalSchool")))
        XCTAssertEqual(try SubredditName.parseNew("https://reddit.com/r/premed", existing: existing).get(), "premed")
    }
}
