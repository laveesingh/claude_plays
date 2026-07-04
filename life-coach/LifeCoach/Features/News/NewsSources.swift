import Foundation

/// A single, source-agnostic news hit normalized across every connector. This is
/// the common currency the aggregator clusters and gates over: a real article URL
/// (never a search snippet), a human outlet name, the source's OWN publication
/// date when we can trust one, and the text we let the LLM summarize from.
///
/// `publishedDate` is `nil` ONLY when the connector genuinely could not supply a
/// date — the aggregator's hard recency gate drops those, which is what fixes the
/// "story filed under fetch time" bug at the root.
struct NewsItem {
    /// The article headline (outlet suffix already stripped for RSS items).
    let title: String
    /// The article URL. For Google News RSS this is the Google redirect link.
    let url: String
    /// The publisher / outlet name, e.g. "Reuters".
    let outlet: String
    /// The source's real publication date; `nil` only when truly unavailable.
    let publishedDate: Date?
    /// A description / content excerpt for the LLM to summarize from.
    let snippet: String
    /// Which connector produced this item: one of "google_news_rss", "gdelt",
    /// "web_search", "newsdata_io".
    let connector: String
    /// The host of `url`, e.g. "reuters.com" (lowercased, "www." stripped).
    var domain: String

    init(title: String,
         url: String,
         outlet: String,
         publishedDate: Date?,
         snippet: String,
         connector: String) {
        self.title = title
        self.url = url
        self.outlet = outlet
        self.publishedDate = publishedDate
        self.snippet = snippet
        self.connector = connector
        self.domain = NewsItem.host(of: url)
    }

    /// The bare host of a URL — lowercased, "www." stripped. Empty string if the
    /// URL has no host (defensive; never crashes).
    static func host(of urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return "" }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}

/// One pluggable feed backend. Each connector knows how to turn a topic + a
/// recency window into normalized `NewsItem`s, and reports whether it is usable
/// at all (e.g. a keyed source with no key is disabled, not an error).
///
/// `fetch` is intentionally non-throwing: a dead source returns `[]` and the
/// aggregator carries on with the rest. This keeps one flaky network call from
/// taking down the whole refresh.
protocol NewsFeedSource {
    /// A short connector identity, also written onto each item's `connector`.
    var name: String { get }
    /// Whether this source can run right now (e.g. has its required key).
    var isEnabled: Bool { get }
    /// Best-effort fetch. `since` is the recency floor the aggregator will also
    /// enforce; connectors may use it to tighten their own queries.
    func fetch(topic: String, since: Date) async -> [NewsItem]
}

// MARK: - Google News RSS

/// Google News RSS search. Free, no key, returns up to ~100 items per query with
/// a real RFC822 `pubDate` and a clean outlet name in the `<source>` element.
///
/// Parsing is delegated to `GoogleNewsRSSParser` (an `XMLParser` delegate) because
/// RSS is a streaming, callback-based format. We URL-encode `"<topic> news"`,
/// request the US English edition, and keep the first 25 items.
struct GoogleNewsRSSSource: NewsFeedSource {
    let name = "google_news_rss"
    /// Always usable — no key required.
    let isEnabled = true

    func fetch(topic: String, since: Date) async -> [NewsItem] {
        let query = "\(topic) news"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=en-US&gl=US&ceid=US:en") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // A UA keeps Google from serving a degraded/blocked response to the
        // default URLSession agent.
        request.setValue("Mozilla/5.0 (compatible; Sapiod/1.0)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        let parser = GoogleNewsRSSParser()
        let raw = parser.parse(data)
        return raw.prefix(25).map { item in
            NewsItem(title: item.title,
                     url: item.link,
                     outlet: item.outlet,
                     publishedDate: item.pubDate,
                     snippet: item.title,    // RSS gives no body; the headline is the snippet
                     connector: name)
        }
    }
}

/// The streaming `XMLParser` delegate that turns a Google News RSS feed into a
/// list of `(title, link, pubDate, outlet)` rows.
///
/// ## How the delegate works
/// `XMLParser` fires `didStartElement` / `foundCharacters` / `didEndElement` as it
/// walks the document. We:
/// - track the current element name and a per-element text buffer,
/// - reset a `RawItem` on each `<item>` start,
/// - accumulate character data into the buffer (RSS 2.0 `<link>`, `<title>`,
///   `<pubDate>`, and `<source>` are ALL text-content elements, so their values
///   arrive via `foundCharacters`),
/// - capture the `<source url="…">` attribute name as the outlet, and
/// - on each element end, copy the trimmed buffer into the right field of the
///   in-flight item; on `</item>` we finalize it.
///
/// The Google title is `"Story headline - Outlet"`; we strip the trailing
/// " - Outlet" to recover the bare headline and keep the `<source>` element as the
/// authoritative outlet (falling back to the stripped suffix if `<source>` is
/// absent).
final class GoogleNewsRSSParser: NSObject, XMLParserDelegate {
    /// A parsed RSS item before normalization.
    struct RawItem {
        var title = ""
        var link = ""
        var outlet = ""
        var pubDate: Date?
    }

    private var items: [RawItem] = []
    private var current: RawItem?
    private var currentElement = ""
    private var buffer = ""
    /// The raw, un-stripped `<title>` text (so we can derive the outlet suffix).
    private var rawTitle = ""

    /// RFC822 dates like "Mon, 22 Jun 2026 07:06:29 GMT".
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    /// Run the parse synchronously and return the rows. Safe to call off the main
    /// thread (it is, from the source's `fetch`).
    func parse(_ data: Data) -> [RawItem] {
        items = []
        current = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        currentElement = elementName
        buffer = ""
        if elementName == "item" {
            current = RawItem()
            rawTitle = ""
        }
        // The outlet name is the TEXT of <source>, but its url is an attribute we
        // ignore. Nothing to capture here — handled on element end.
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            rawTitle = text
            current?.title = Self.stripOutletSuffix(text)
        case "link":
            if current != nil { current?.link = text }
        case "pubDate":
            current?.pubDate = Self.rfc822.date(from: text)
        case "source":
            if !text.isEmpty { current?.outlet = text }
        case "item":
            if var item = current {
                // Fall back to the title's trailing " - Outlet" when <source> was absent.
                if item.outlet.isEmpty {
                    item.outlet = Self.outletSuffix(rawTitle) ?? Self.host(item.link)
                }
                if !item.title.isEmpty, !item.link.isEmpty {
                    items.append(item)
                }
            }
            current = nil
        default:
            break
        }
        buffer = ""
    }

    // MARK: Title helpers

    /// "Story headline - Reuters" → "Story headline". Strips only the LAST
    /// " - <outlet>" segment (titles can contain hyphens of their own).
    private static func stripOutletSuffix(_ title: String) -> String {
        guard let range = title.range(of: " - ", options: .backwards) else { return title }
        return String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The trailing outlet of "Story headline - Reuters" → "Reuters".
    private static func outletSuffix(_ title: String) -> String? {
        guard let range = title.range(of: " - ", options: .backwards) else { return nil }
        let suffix = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func host(_ urlString: String) -> String {
        NewsItem.host(of: urlString)
    }
}

// MARK: - GDELT

/// GDELT's DOC 2.0 article list. Free, no key, structured `seendate`, but rate
/// limited to ONE request per 5 seconds globally — so `fetch` sleeps 5.5s before
/// firing. We request the last 7 days, newest first, English only.
///
/// GDELT carries no publisher-name field, so the outlet is derived from the
/// article `domain` ("blic.rs" → "Blic", "reuters.com" → "Reuters").
struct GDELTSource: NewsFeedSource {
    let name = "gdelt"
    /// Always usable — no key required.
    let isEnabled = true

    /// "20260626T063000Z" UTC timestamps.
    private static let seendate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    func fetch(topic: String, since: Date) async -> [NewsItem] {
        // Hard rate limit: GDELT rejects (or throttles) bursts under 5s apart.
        // Sleeping here keeps the source self-contained — the aggregator only has
        // to call it sequentially, not orchestrate the delay.
        try? await Task.sleep(nanoseconds: 5_500_000_000)

        guard let encoded = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.gdeltproject.org/api/v2/doc/doc?query=\(encoded)&mode=ArtList&format=json&timespan=7d&sort=DateDesc&maxrecords=25") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (compatible; Sapiod/1.0)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let articles = object["articles"] as? [[String: Any]] else {
            return []
        }

        return articles.compactMap { article -> NewsItem? in
            // English-only.
            guard (article["language"] as? String) == "English" else { return nil }
            guard let url = (article["url"] as? String), !url.isEmpty,
                  let title = (article["title"] as? String), !title.isEmpty else { return nil }
            let domain = (article["domain"] as? String) ?? NewsItem.host(of: url)
            let date = (article["seendate"] as? String).flatMap { Self.seendate.date(from: $0) }
            return NewsItem(title: title,
                            url: url,
                            outlet: Self.outletName(from: domain),
                            publishedDate: date,
                            snippet: title,
                            connector: name)
        }
    }

    /// "blic.rs" → "Blic", "reuters.com" → "Reuters". Drops the TLD and
    /// capitalizes the first label.
    static func outletName(from domain: String) -> String {
        let lowered = domain.lowercased()
        let stripped = lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
        // The leading label before the first dot is the outlet stem.
        let stem = stripped.split(separator: ".").first.map(String.init) ?? stripped
        guard let first = stem.first else { return domain }
        return first.uppercased() + stem.dropFirst()
    }
}

// MARK: - Web search

/// Wraps the existing `GroundingService` web search as a news source. Adds a few
/// platform exclusions to the query to keep blog/newsletter farms out, and uses
/// `DateExtractor` to recover each result's real date (the search API gives none).
///
/// Degrades gracefully: if the grounding backend has no key / throws, `fetch`
/// returns `[]` rather than failing the refresh.
struct WebSearchNewsSource: NewsFeedSource {
    let name = "web_search"
    /// Always attempt it; it self-disables by returning `[]` when grounding throws.
    let isEnabled = true

    /// Injected so tests / callers can swap the backend; defaults to the shared one.
    let grounding: Grounding

    init(grounding: Grounding = GroundingService.shared) {
        self.grounding = grounding
    }

    func fetch(topic: String, since: Date) async -> [NewsItem] {
        let query = "\(topic) news -site:medium.com -site:substack.com"
        guard let results = try? await grounding.search(query, maxResults: 10) else {
            return []
        }
        return results.map { result in
            let date = DateExtractor.date(title: result.title, url: result.url, content: result.content)
            return NewsItem(title: result.title,
                            url: result.url,
                            outlet: NewsItem.host(of: result.url),
                            publishedDate: date,
                            snippet: result.content,
                            connector: name)
        }
    }
}

// MARK: - NewsData.io (keyed)

/// NewsData.io full-text news search. Optional — only runs when the user has saved
/// a `Secret.newsDataKey` in the Keychain; with no key the source is simply
/// disabled (not an error). Adds a fourth, full-text source on top of the three
/// keyless ones.
struct KeyedNewsAPISource: NewsFeedSource {
    let name = "newsdata_io"

    /// Enabled only when a key is present.
    var isEnabled: Bool { KeychainHelper.hasKey(secret: .newsDataKey) }

    /// "2026-06-20 14:30:00" UTC pubDates.
    private static let pubDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func fetch(topic: String, since: Date) async -> [NewsItem] {
        guard let key = KeychainHelper.load(secret: .newsDataKey), !key.isEmpty else { return [] }
        guard let encoded = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://newsdata.io/api/1/news?apikey=\(key)&q=\(encoded)&language=en") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["status"] as? String) == "ok",
              let results = object["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { result -> NewsItem? in
            // Note: NewsData.io uses "link", NOT "url".
            guard let link = (result["link"] as? String), !link.isEmpty,
                  let title = (result["title"] as? String), !title.isEmpty else { return nil }
            let outlet = (result["source_name"] as? String) ?? NewsItem.host(of: link)
            let snippet = (result["description"] as? String) ?? title
            let date = (result["pubDate"] as? String).flatMap { Self.pubDate.date(from: $0) }
            return NewsItem(title: title,
                            url: link,
                            outlet: outlet,
                            publishedDate: date,
                            snippet: snippet,
                            connector: name)
        }
    }
}
