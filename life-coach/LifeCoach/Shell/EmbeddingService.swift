import Foundation
import NaturalLanguage

/// On-device sentence embeddings, powered by Apple's `NLEmbedding`. Fully local —
/// no network, no API key, no data leaves the device. This single service backs
/// BOTH Factscroll's semantic dedup (cosine between fact vectors) and its taste
/// re-rank (cosine between a fact and the learned taste vector).
///
/// `NLEmbedding.sentenceEmbedding(for: .english)` is loaded once and cached on the
/// singleton; it is the expensive part, so we never re-create it per call.
///
/// The model may legitimately return `nil` for a vector (unsupported language,
/// empty/degenerate text). Callers MUST handle `nil` and fall back rather than
/// treating it as "no duplicate" / "no taste" — see `FactDedup` (token-overlap
/// fallback) and `TasteEngine` (keep-first-N fallback).
final class EmbeddingService {
    /// Shared, cached instance. The embedding model load happens once, lazily.
    static let shared = EmbeddingService()

    /// The cached sentence embedding, or `nil` if the platform/model is
    /// unavailable. Loaded once at init.
    private let sentenceEmbedding: NLEmbedding?

    private init() {
        sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// The dimensionality of the loaded embedding (0 if unavailable). Exposed so
    /// callers/tests can sanity-check vectors; on current iOS the English sentence
    /// embedding is 512-dimensional.
    var dimension: Int { sentenceEmbedding?.dimension ?? 0 }

    /// Embed `text` into a dense vector, or `nil` if embedding is unavailable or
    /// the text produces no usable vector. The text is trimmed first; empty text
    /// returns `nil`.
    func vector(for text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding = sentenceEmbedding else { return nil }
        guard let vector = embedding.vector(for: trimmed), !vector.isEmpty else { return nil }
        return vector
    }

    /// Cosine similarity of two vectors in [-1, 1]. Returns 0 when the vectors are
    /// empty, mismatched in length, or zero-magnitude — i.e. "no signal", never a
    /// false match.
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
