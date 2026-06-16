import Foundation

/// Real cover images from Unsplash. Conforms to the same `FactImageService` the
/// feed depends on, so it drops in with no view changes: for a topic it searches
/// Unsplash, deterministically picks one portrait photo, and returns a `FactImage`
/// whose `remoteURL` is that photo — keeping the topic-derived gradient (from the
/// mock) as the load placeholder / fallback base.
///
/// Resilient by construction: no key, a network error, or zero results all fall
/// back to the gradient-only image, so the feed never breaks because of images.
/// The Unsplash access key is read from the Keychain (entered in Settings).
struct UnsplashImageService: FactImageService {
    /// Supplies the gradient + symbol base every image keeps as its placeholder.
    private let gradients = MockFactImageService()

    private static let searchEndpoint = "https://api.unsplash.com/search/photos"

    func cover(for topic: String) async -> FactImage {
        // Always have the gradient ready — it's the placeholder and the fallback.
        let base = await gradients.cover(for: topic)

        guard let key = KeychainHelper.load(secret: .unsplash), !key.isEmpty,
              let photo = await fetchPhoto(for: topic, key: key) else {
            return base
        }

        // Per Unsplash API guidelines, ping the download-tracking endpoint when a
        // photo is used. Fire-and-forget; failure is irrelevant to the user.
        if let tracking = photo.downloadLocation {
            Task.detached { await Self.track(tracking, key: key) }
        }

        return FactImage(startColor: base.startColor,
                         endColor: base.endColor,
                         symbol: base.symbol,
                         remoteURL: photo.url)
    }

    // MARK: - Networking

    private struct UnsplashPhoto {
        let url: URL
        let downloadLocation: String?
    }

    /// Search Unsplash for `topic` and pick ONE photo deterministically (a stable
    /// hash of the topic indexes into the results) so the same topic always shows
    /// the same picture across scrolls and launches.
    private func fetchPhoto(for topic: String, key: String) async -> UnsplashPhoto? {
        let query = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              var components = URLComponents(string: Self.searchEndpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "orientation", value: "portrait"),
            URLQueryItem(name: "content_filter", value: "high"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]], !results.isEmpty else {
            return nil
        }

        // Deterministic pick: same topic -> same photo.
        let index = Self.stableHash(query.lowercased()) % results.count
        let chosen = results[index]

        guard let urls = chosen["urls"] as? [String: Any],
              let regular = urls["regular"] as? String,
              let photoURL = URL(string: regular) else { return nil }

        let links = chosen["links"] as? [String: Any]
        let downloadLocation = links?["download_location"] as? String
        return UnsplashPhoto(url: photoURL, downloadLocation: downloadLocation)
    }

    /// GET the photo's `download_location` to register a download per Unsplash's
    /// API guidelines. Best-effort, response ignored.
    private static func track(_ location: String, key: String) async {
        guard let url = URL(string: location) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// FNV-1a, salt-free so it's stable across launches (Swift's `Hasher` isn't).
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(Int.max))
    }
}
