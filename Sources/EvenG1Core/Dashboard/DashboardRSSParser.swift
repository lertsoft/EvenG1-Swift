import Foundation

/// Parses RSS 2.0 and Atom feeds into a headline suitable for the dashboard.
public enum DashboardRSSParser {
    public struct Headline: Sendable, Equatable {
        public var source: String
        public var title: String

        public init(source: String, title: String) {
            self.source = source
            self.title = title
        }
    }

    public enum ParseError: Error, Sendable {
        case noItems
        case invalidXML
    }

    public static func parseTopHeadline(from data: Data, feedURL: URL? = nil) throws -> Headline {
        let delegate = FeedParserDelegate(feedURL: feedURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML
        }
        guard let headline = delegate.firstHeadline else {
            throw ParseError.noItems
        }
        return headline
    }
}

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private let feedURL: URL?

    private var feedTitle = ""
    fileprivate var firstHeadline: DashboardRSSParser.Headline?

    private var currentElement = ""
    private var currentTitle = ""
    private var currentSource = ""
    private var isInsideItem = false
    private var isInsideEntry = false
    private var captureTitle = false
    private var captureSource = false

    init(feedURL: URL?) {
        self.feedURL = feedURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        switch elementName {
        case "item":
            isInsideItem = true
            currentTitle = ""
            currentSource = ""
        case "entry":
            isInsideEntry = true
            currentTitle = ""
            currentSource = ""
        case "title":
            if isInsideItem || isInsideEntry {
                captureTitle = true
            }
        case "source":
            if isInsideItem || isInsideEntry {
                captureSource = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if currentElement == "title", !isInsideItem, !isInsideEntry {
            feedTitle.append(trimmed)
            return
        }

        if captureTitle {
            currentTitle.append(trimmed)
        } else if captureSource {
            currentSource.append(trimmed)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "title":
            captureTitle = false
        case "source":
            captureSource = false
        case "item", "entry":
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, firstHeadline == nil {
                let source = resolvedSource()
                firstHeadline = DashboardRSSParser.Headline(source: source, title: title)
            }
            isInsideItem = false
            isInsideEntry = false
            currentTitle = ""
            currentSource = ""
        default:
            break
        }
        currentElement = ""
    }

    private func resolvedSource() -> String {
        let explicit = currentSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }

        let channel = feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channel.isEmpty { return channel }

        if let host = feedURL?.host?.replacingOccurrences(of: "www.", with: "") {
            return host
        }

        return "News"
    }
}
