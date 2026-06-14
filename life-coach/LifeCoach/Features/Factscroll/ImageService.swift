import SwiftUI

/// The renderable background for a fact slide. Designed so a real network image
/// service can swap in with ZERO view changes: today every `FactImage` is a
/// deterministic gradient (+ optional SF Symbol motif) and `remoteURL` is nil;
/// once Unsplash lands, `remoteURL` carries a photo URL and the view layers it
/// over the same gradient (which then doubles as a load placeholder / scrim base).
struct FactImage: Hashable {
    /// The two gradient hues (0...1) derived from the topic. Always present so a
    /// slide always has an aesthetic background even with no network.
    let startColor: GradientColor
    let endColor: GradientColor

    /// An optional SF Symbol motif drawn faintly over the gradient to give each
    /// topic a little visual identity. nil means "gradient only".
    let symbol: String?

    /// Left nil today. A real `UnsplashImageService` fills this with a photo URL;
    /// the view renders it over the gradient with `AsyncImage`. No other change.
    let remoteURL: URL?

    init(startColor: GradientColor,
         endColor: GradientColor,
         symbol: String? = nil,
         remoteURL: URL? = nil) {
        self.startColor = startColor
        self.endColor = endColor
        self.symbol = symbol
        self.remoteURL = remoteURL
    }
}

/// A Codable-friendly, Hashable color expressed in HSB. Kept independent of
/// SwiftUI's `Color` (which isn't Hashable) so `FactImage` stays value-comparable
/// and a future cache could persist it.
struct GradientColor: Hashable {
    let hue: Double         // 0...1
    let saturation: Double  // 0...1
    let brightness: Double  // 0...1

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

/// Source of a fact's full-screen cover image. The store/view depend only on
/// this abstraction.
///
// TODO: UnsplashImageService swaps in once the access key lands — it conforms to
// this same protocol, queries Unsplash for `topic`, and returns a `FactImage`
// whose `remoteURL` is the chosen photo (keeping a gradient fallback for the
// load/placeholder state). No view changes required.
protocol FactImageService {
    /// A cover background for a fact tagged with `topic`. Async to match the
    /// future networked implementation; the mock returns immediately.
    func cover(for topic: String) async -> FactImage
}

/// Deterministic, aesthetic, NO-NETWORK image service: hashes the topic into two
/// complementary-ish hues and a saturation/brightness pair tuned to read well
/// behind white text, plus a topic-derived SF Symbol motif. The same topic
/// always yields the same gradient, so the feed feels stable across scrolls.
struct MockFactImageService: FactImageService {
    func cover(for topic: String) async -> FactImage {
        let key = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = Self.stableHash(key)

        // Two hues: a base hue and a second offset ~0.18–0.42 around the wheel,
        // giving a pleasant, non-garish two-tone (never a muddy near-identical pair).
        let startHue = Double(seed % 360) / 360.0
        let spread = 0.18 + Double((seed >> 9) % 25) / 100.0   // 0.18 ... 0.42
        let endHue = (startHue + spread).truncatingRemainder(dividingBy: 1.0)

        // Rich but text-safe: deep, slightly varied saturation/brightness so the
        // scrim + white text always have contrast.
        let saturation = 0.55 + Double((seed >> 4) % 25) / 100.0   // 0.55 ... 0.79
        let startBrightness = 0.45 + Double((seed >> 6) % 20) / 100.0 // 0.45 ... 0.64
        let endBrightness = 0.30 + Double((seed >> 8) % 20) / 100.0   // 0.30 ... 0.49

        return FactImage(
            startColor: GradientColor(hue: startHue, saturation: saturation, brightness: startBrightness),
            endColor: GradientColor(hue: endHue, saturation: min(1.0, saturation + 0.1), brightness: endBrightness),
            symbol: Self.symbol(for: key, seed: seed),
            remoteURL: nil
        )
    }

    /// A stable, platform-independent hash (Swift's `Hasher` is salted per run,
    /// so it can't be used for cross-launch determinism). Simple FNV-1a.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Fold into a positive Int range.
        return Int(hash % UInt64(Int.max))
    }

    /// A small, curated SF Symbol palette. We first try to match a few common
    /// topic families by keyword (so "space" reliably gets a star), then fall
    /// back to a deterministic pick from the palette by seed.
    private static func symbol(for topic: String, seed: Int) -> String {
        for (keywords, symbol) in keywordSymbols {
            if keywords.contains(where: { topic.contains($0) }) {
                return symbol
            }
        }
        return palette[seed % palette.count]
    }

    private static let keywordSymbols: [(keywords: [String], symbol: String)] = [
        (["space", "astro", "cosmos", "star", "planet", "galaxy"], "sparkles"),
        (["ocean", "sea", "water", "marine", "fish"], "drop.fill"),
        (["animal", "biology", "nature", "wildlife"], "leaf.fill"),
        (["history", "ancient", "war", "empire"], "scroll.fill"),
        (["body", "brain", "health", "medicine", "human"], "brain.head.profile"),
        (["tech", "computer", "internet", "math", "science"], "function"),
        (["music", "sound", "art"], "music.note"),
        (["food", "plant", "agriculture"], "carrot.fill"),
        (["language", "word", "book"], "text.book.closed.fill"),
        (["weather", "climate", "earth"], "globe.americas.fill"),
    ]

    private static let palette = [
        "sparkles", "globe.americas.fill", "atom", "leaf.fill", "flame.fill",
        "bolt.fill", "moon.stars.fill", "drop.fill", "wind", "mountain.2.fill",
    ]
}
