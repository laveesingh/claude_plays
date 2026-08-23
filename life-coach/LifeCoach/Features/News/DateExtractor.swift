import Foundation

/// Pulls a publication date out of a web result's noisy text.
///
/// The `web_search` API returns no structured date field, but the date almost
/// always appears in plain sight: as an explicit `Published:`/`Updated:` ISO
/// stamp near the top of the extracted content, inside the URL path
/// (`/2026-06-15/`), or in the title (`15-06-2026`). We scan those sources in
/// order of reliability and return the first plausible date — never a future one
/// and never an absurdly old one — so a stray number can't masquerade as a date.
///
/// This is what lets News file each story under its REAL date instead of the
/// moment we happened to fetch it.
enum DateExtractor {
    /// A short ISO day string (`yyyy-MM-dd`) for the most plausible publication
    /// date found across `content`, `url`, and `title`, or nil if none is found.
    /// Returned as a string so it can be handed to the model verbatim and parsed
    /// back through the same `yyyy-MM-dd` path everywhere.
    static func isoDay(title: String, url: String, content: String) -> String? {
        date(title: title, url: url, content: content).map { dayFormatter.string(from: $0) }
    }

    /// The most plausible publication `Date`, scanning content → url → title.
    static func date(title: String, url: String, content: String) -> Date? {
        // 1. An explicit labeled stamp ("Published: 2026-06-10T…") is the strongest
        //    signal — these sit at the head of most article extractions.
        if let d = labeledISODate(in: content) { return d }
        // 2. Any bare ISO day in the (head of the) content.
        if let d = firstISODate(in: contentHead(content)) { return d }
        // 3. A date baked into the URL path.
        if let d = urlDate(in: url) { return d }
        // 4. A date in the title (often "DD-MM-YYYY" or "Month DD, YYYY").
        if let d = naturalDate(in: title) { return d }
        // 5. Last resort: a natural-language date anywhere in the content head.
        if let d = naturalDate(in: contentHead(content)) { return d }
        return nil
    }

    // MARK: - Sources

    /// Only the first slice of content is scanned for bare/natural dates — bylines
    /// and stamps live at the top, and it keeps a 10k-char page from yielding a
    /// random in-body date.
    private static func contentHead(_ content: String) -> String {
        String(content.prefix(600))
    }

    /// "Published: 2026-06-10T09:00:41+00:00" / "Updated 2026-06-09" → the date.
    /// Searches the whole content because the label reliably guards against a
    /// false positive.
    private static func labeledISODate(in text: String) -> Date? {
        guard let regex = Self.labeledISORegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return parseISODay(String(text[r]))
    }

    /// First bare `yyyy-mm-dd` in the text.
    private static func firstISODate(in text: String) -> Date? {
        guard let regex = Self.bareISORegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return parseISODay(String(text[r]))
    }

    /// `…/2026-06-15/…` or `…/2026/06/15/…` in a URL path.
    private static func urlDate(in url: String) -> Date? {
        guard let regex = Self.urlDateRegex else { return nil }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = regex.firstMatch(in: url, range: range),
              match.numberOfRanges >= 4,
              let yr = Range(match.range(at: 1), in: url),
              let mr = Range(match.range(at: 2), in: url),
              let dr = Range(match.range(at: 3), in: url),
              let year = Int(url[yr]), let month = Int(url[mr]), let day = Int(url[dr]) else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    /// Apple's `NSDataDetector` handles "June 10, 2026", "10 June 2026",
    /// "06/10/2026", "15-06-2026", etc. We take the first detected date that
    /// passes the plausibility window.
    private static func naturalDate(in text: String) -> Date? {
        guard let detector = Self.dateDetector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: Date?
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            if let date = match?.date, isPlausible(date) {
                found = date
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Parsing & validation

    private static func parseISODay(_ raw: String) -> Date? {
        // Take just the leading yyyy-MM-dd, ignoring any time/zone suffix.
        let day = String(raw.prefix(10))
        guard let date = dayFormatter.date(from: day), isPlausible(date) else { return nil }
        return date
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: c), isPlausible(date) else { return nil }
        return date
    }

    /// A date is plausible if it isn't in the future (1-day TZ slack) and isn't
    /// older than a few years — news is recent, and this rejects garbage matches.
    private static func isPlausible(_ date: Date) -> Bool {
        let now = Date()
        if date > now.addingTimeInterval(36 * 3600) { return false }       // not future
        if date < now.addingTimeInterval(-5 * 365 * 24 * 3600) { return false } // not ancient
        return true
    }

    // MARK: - Shared formatters / regexes

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let labeledISORegex = try? NSRegularExpression(
        pattern: #"(?i)(?:published|updated|posted|date)[^0-9]{0,15}(\d{4}-\d{2}-\d{2})"#)
    private static let bareISORegex = try? NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}"#)
    private static let urlDateRegex = try? NSRegularExpression(
        pattern: #"/(\d{4})[-/](\d{2})[-/](\d{2})(?:[-/]|$)"#)
    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)
}
