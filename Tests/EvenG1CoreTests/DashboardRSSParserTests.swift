import XCTest
@testable import EvenG1Core

final class DashboardRSSParserTests: XCTestCase {
    func testParsesRSSItem() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example News</title>
            <item>
              <title>First headline</title>
              <source>Wire</source>
            </item>
            <item>
              <title>Second headline</title>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let headline = try DashboardRSSParser.parseTopHeadline(from: xml)
        XCTAssertEqual(headline.source, "Wire")
        XCTAssertEqual(headline.title, "First headline")
    }

    func testParsesAtomEntry() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Feed</title>
          <entry>
            <title>Atom headline</title>
          </entry>
        </feed>
        """.data(using: .utf8)!

        let headline = try DashboardRSSParser.parseTopHeadline(from: xml)
        XCTAssertEqual(headline.source, "Atom Feed")
        XCTAssertEqual(headline.title, "Atom headline")
    }
}
