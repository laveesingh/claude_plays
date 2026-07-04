import Foundation
import WhisperKit

/// On-device speech-to-text for the "Ask your inbox" voice layer, wrapping
/// WhisperKit. Initialization and model download are **lazy** — nothing happens
/// until `transcribe(audioPath:)` is first called. The wrapper pins a small
/// English model so first-use download is fast (<150 MB).
///
/// WhisperKit API used (verified against argmax-oss-swift 1.0.0):
/// ```
/// init(model: String?, download: Bool, …) async throws
/// transcribe(audioPath: String, …) async throws -> [TranscriptionResult]
/// ```
/// `TranscriptionResult.text` is the concatenated transcript string.
@MainActor
final class InboxVoiceSTT: ObservableObject {

    // MARK: - State

    /// Mirrors the model-download / ready state for the UI to gate the mic button.
    enum Status: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    // MARK: - Private state

    /// Lazily created on first `transcribe` call.
    private var kit: WhisperKit?

    /// The WhisperKit model variant to pin. "openai_whisper-base.en" is the
    /// smallest English-only model (~75 MB on-device) that ships with solid
    /// accuracy for short voice queries.
    private static let modelName = "openai_whisper-base.en"

    // MARK: - Public API

    /// Transcribe an audio file at `audioPath` to a plain-text string.
    ///
    /// On the first call this downloads and compiles the Whisper model (slow;
    /// subsequent calls are instant). Emits `status` updates so the UI can show
    /// a progress indicator.
    ///
    /// - Parameter audioPath: URL of the recorded audio file (m4a/wav/mp3/flac).
    /// - Returns: The best-effort transcript, trimmed of whitespace.
    /// - Throws: Any WhisperKit error (network failure, model load, decoding).
    func transcribe(audioPath: URL) async throws -> String {
        let engine = try await ensureKit()
        let results = try await engine.transcribe(audioPath: audioPath.path)
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    /// Return the live `WhisperKit` instance, initializing it on first call.
    private func ensureKit() async throws -> WhisperKit {
        if let kit { return kit }

        status = .downloading
        do {
            // `download: true` fetches the model from Hugging Face on first run
            // and caches it in the app's Documents directory automatically.
            let engine = try await WhisperKit(
                model: Self.modelName,
                verbose: false,
                download: true
            )
            kit = engine
            status = .ready
            return engine
        } catch {
            let message = error.localizedDescription
            status = .failed(message)
            throw error
        }
    }
}
