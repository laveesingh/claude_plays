import Foundation

/// Token-overlap dedup — now the **fallback layer** beneath the embedding
/// pipeline in `FactscrollStore`. The primary dedup is (1) exact canonical
/// `claim_key` match, then (2) semantic cosine over on-device `NLEmbedding`
/// vectors. This token-overlap check is used only when `EmbeddingService` can't
/// produce a vector for a fact (so dedup is never silently disabled).
///
/// The #1 known failure mode is the model re-emitting the *same* fact disguised
/// in different words ("Octopuses have three hearts" vs "An octopus has a trio
/// of hearts"). The fallback attacks that two ways:
///
///   1. A normalized `signature` per fact — lowercased, stop-words stripped,
///      significant tokens sorted & de-duplicated, joined. Identical claims with
///      reordered/reworded filler collapse to the same (or a very close) key.
///   2. A token-overlap (Jaccard) check between a candidate's significant tokens
///      and every recent signature's tokens; anything above `jaccardThreshold`
///      (~0.6) is treated as a near-duplicate and dropped.
enum FactDedup {
    /// Jaccard token-overlap above this counts as a near-duplicate. v1 value.
    static let jaccardThreshold = 0.6

    /// Common filler that carries no claim-identity. Stripped before signing so
    /// "the octopus has three hearts" and "an octopus has three hearts" align.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with",
        "and", "or", "but", "is", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "as", "from", "into",
        "than", "then", "so", "such", "can", "could", "would", "will", "has",
        "have", "had", "do", "does", "did", "about", "up", "out", "if", "they",
        "their", "there", "which", "who", "whom", "you", "your", "we", "our",
        "all", "any", "more", "most", "some", "one", "also", "actually", "fact",
        "did", "you", "know", "interesting", "surprising",
    ]

    /// Derive a fact's canonical signature. The normalized significant tokens,
    /// sorted and joined by spaces.
    static func signature(for text: String) -> String {
        significantTokens(text).sorted().joined(separator: " ")
    }

    /// The set of significant (non-stop, length >= 3) tokens for a piece of text.
    /// Numbers are kept (they're often the heart of a fact). Used for Jaccard.
    static func significantTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let tokens = String(String.UnicodeScalarView(cleaned.map { $0.unicodeScalars.first! }))
            .split(separator: " ")
            .map(String.init)
        return Set(tokens.filter { token in
            guard token.count >= 3 || token.allSatisfy(\.isNumber) else { return false }
            return !stopWords.contains(token)
        })
    }

    /// Jaccard similarity (|A∩B| / |A∪B|) of two token sets. 0 = disjoint,
    /// 1 = identical.
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Decide whether a candidate fact collides with anything already seen.
    /// `seenSignatures` is the ledger (signatures of facts we've already shown).
    /// Returns true if the candidate is an exact signature match OR exceeds the
    /// Jaccard threshold against any seen signature.
    ///
    /// We also pass `withinBatch` — signatures accepted earlier in the SAME batch
    /// — so the model can't slip two rephrasings of one claim past us at once.
    static func isDuplicate(candidateSignature: String,
                            against seenSignatures: [String],
                            withinBatch batchSignatures: [String]) -> Bool {
        let candidateTokens = Set(candidateSignature.split(separator: " ").map(String.init))
        guard !candidateTokens.isEmpty else { return true } // empty signature == junk, drop it

        for existing in seenSignatures + batchSignatures {
            if existing == candidateSignature { return true }
            let existingTokens = Set(existing.split(separator: " ").map(String.init))
            if jaccard(candidateTokens, existingTokens) > jaccardThreshold {
                return true
            }
        }
        return false
    }
}
