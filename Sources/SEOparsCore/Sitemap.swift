import Foundation

/// Разбор sitemap.xml и индексных sitemap.
public enum SitemapParser {
    public struct Result: Sendable, Equatable {
        public var urls: [String] = []
        public var sitemaps: [String] = []
    }

    public static func parse(_ data: Data) -> Result {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = Result()
        var stack: [String] = []
        var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName.lowercased())
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.lowercased()
            if name == "loc", stack.count >= 2 {
                let parent = stack[stack.count - 2]
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    if parent == "url" { result.urls.append(value) }
                    else if parent == "sitemap" { result.sitemaps.append(value) }
                }
            }
            _ = stack.popLast()
            text = ""
        }
    }
}
