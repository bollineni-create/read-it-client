import XCTest
@testable import RoundsCore

final class LinkExtractorTests: XCTestCase {
    func testExtractsMarkdownAndBareLinksInOrder() {
        let text = """
        Check [the AAMC guide](https://www.aamc.org/guide) and also https://example.com/a.pdf.
        Plus (see https://en.wikipedia.org/wiki/Krebs_cycle_(biology)) for more.
        """
        let links = LinkExtractor.extract(from: text)
        XCTAssertEqual(links.map(\.url), [
            "https://aamc.org/guide",
            "https://example.com/a.pdf",
            "https://en.wikipedia.org/wiki/Krebs_cycle_(biology)",
        ])
        XCTAssertEqual(links[0].title, "the AAMC guide")
        XCTAssertEqual(links[0].domain, "aamc.org")
        XCTAssertEqual(links[1].title, "a.pdf")
    }

    func testStripsTrackingParametersAndFragments() {
        let n = LinkExtractor.normalize("HTTPS://WWW.Example.com/path/?utm_source=reddit&id=42&fbclid=abc&utm_medium=social#section")
        XCTAssertEqual(n?.url, "https://example.com/path?id=42")
        XCTAssertEqual(n?.domain, "example.com")
        XCTAssertEqual(LinkExtractor.normalize("https://example.com/?gclid=1")?.url, "https://example.com")
        XCTAssertEqual(LinkExtractor.normalize("https://docs.google.com/spreadsheets/d/abc/edit?usp=sharing&utm_campaign=x")?.url,
                       "https://docs.google.com/spreadsheets/d/abc/edit?usp=sharing")
        XCTAssertEqual(LinkExtractor.normalize("https://example.com:443/x")?.url, "https://example.com/x")
    }

    func testUnwrapsRedirectors() {
        let wrapped = "https://www.google.com/url?q=https%3A%2F%2Fwww.nature.com%2Farticles%2Fs41586%3Futm_source%3Dx&sa=D"
        XCTAssertEqual(LinkExtractor.normalize(wrapped)?.url, "https://nature.com/articles/s41586")
    }

    func testDeduplicatesAfterNormalization() {
        let text = "https://example.com/notes.pdf?fbclid=1 and https://www.example.com/notes.pdf and [notes](https://example.com/notes.pdf#p2)"
        let links = LinkExtractor.extract(from: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.url, "https://example.com/notes.pdf")
    }

    func testSkipsRedditLinksAndHandlesEntitiesAndEscapes() {
        let text = "See https://www.reddit.com/r/mdphd/wiki and https://redd.it/abc and https://example.com/a?x=1&amp;y=2 and https://example.com/some\\_file"
        let links = LinkExtractor.extract(from: text)
        XCTAssertEqual(links.map(\.url), ["https://example.com/a?x=1&y=2", "https://example.com/some_file"])
    }

    func testTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(LinkExtractor.trimTrailing("https://a.com/x)."), "https://a.com/x")
        XCTAssertEqual(LinkExtractor.trimTrailing("https://a.com/x_(y)"), "https://a.com/x_(y)")
        XCTAssertEqual(LinkExtractor.extract(from: "(https://a.com/page)").first?.url, "https://a.com/page")
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(LinkExtractor.normalize("mailto:someone@example.com"))
        XCTAssertNil(LinkExtractor.normalize("ftp://example.com/file"))
    }

    func testImageHostDetection() {
        XCTAssertTrue(LinkExtractor.isImageHost("https://i.redd.it/abc.png"))
        XCTAssertTrue(LinkExtractor.isImageHost("https://example.com/pic.JPG"))
        XCTAssertFalse(LinkExtractor.isImageHost("https://example.com/doc.pdf"))
    }
}

final class ThreadClassifierTests: XCTestCase {
    func testQuestionTitles() {
        XCTAssertEqual(ThreadClassifier.classify(title: "Is an MD-PhD worth it?", body: "", postLinks: []), .question)
        XCTAssertEqual(ThreadClassifier.classify(title: "How do people study for Step 1", body: "", postLinks: []), .question)
        XCTAssertEqual(ThreadClassifier.classify(title: "Matched into my top choice!", body: "", postLinks: []), .discussion)
    }

    func testResources() {
        let sheet = LinkExtractor.extract(from: "https://docs.google.com/spreadsheets/d/abc")
        XCTAssertEqual(ThreadClassifier.classify(title: "My school list", body: "", postLinks: sheet), .resource)
        XCTAssertEqual(ThreadClassifier.classify(title: "Free Anki deck for pharm", body: "", postLinks: []), .resource)
        let pdf = LinkExtractor.extract(from: "https://example.com/handout.pdf")
        XCTAssertEqual(ThreadClassifier.classify(title: "What do you think?", body: "", postLinks: pdf), .resource)
        let image = LinkExtractor.extract(from: "https://i.imgur.com/abc.png")
        XCTAssertEqual(ThreadClassifier.classify(title: "Look at this", body: "", postLinks: image), .discussion)
    }
}
