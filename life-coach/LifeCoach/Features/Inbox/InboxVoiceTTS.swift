import Foundation
import AVFoundation
import FluidAudio

// MARK: - InboxVoiceTTS

/// On-device text-to-speech for the "Ask your inbox" voice layer, backed
/// by **Kokoro-82M** via the FluidAudio Swift package (`KokoroAneManager`).
///
/// ## Architecture
///
/// `KokoroAneManager` is a Swift `actor` that runs the Kokoro 82M CoreML
/// chain (7-stage ANE graph) and returns synthesis results as 24 kHz mono
/// 16-bit PCM WAV `Data`. `InboxVoiceTTS` bridges that into a
/// `@MainActor`-isolated `ObservableObject` by:
///
///   1. Lazy-initialising `KokoroAneManager` on the first `speak(_:)` call.
///   2. Calling `initialize()` once (downloads the CoreML models from HF on
///      the first device run — several hundred MB; subsequent runs hit the
///      on-disk cache and are near-instant).
///   3. Calling `synthesize(text:voice:speed:)` → WAV `Data` on the actor.
///   4. Writing the WAV bytes to a temp file and playing with `AVAudioPlayer`.
///
/// ## Simulator vs Device
///
/// CoreML / ANE inference does **not** run in the iOS Simulator (no Neural
/// Engine hardware). `KokoroAneManager` will still compile and its
/// `initialize()` / `synthesize()` paths will be reached at runtime, but
/// CoreML predictions will fail on the simulator. The code catches every
/// error and falls back to `AVSpeechSynthesizer` so the user always hears
/// a reply — on device or in the simulator.
///
/// ## First-use model download
///
/// `initialize()` triggers an automatic download of the Kokoro-82M CoreML
/// models from HuggingFace (`FluidInference/kokoro-82m-coreml`) the first
/// time it is called on a fresh install. This can take tens of seconds on
/// a slow connection. `InboxVoiceTTS` surfaces a `"preparing voice…"` status
/// during that window via `@Published var status`.
///
/// ## Fallback
///
/// Any `KokoroAneManager` error (offline, model download failure, CoreML
/// prediction failure in the simulator) causes a transparent silent fallback
/// to `AVSpeechSynthesizer`, which is iOS-native and requires no download.
@MainActor
final class InboxVoiceTTS: NSObject, ObservableObject {

    // MARK: - Status

    /// Human-readable status for display in the UI while Kokoro is loading.
    enum Status: Equatable {
        /// Idle — no synthesis in progress.
        case idle
        /// Downloading or loading the Kokoro CoreML model bundle.
        case preparingVoice
        /// Synthesis is running (Kokoro or fallback).
        case speaking
        /// Kokoro was unavailable; the current utterance used the system TTS.
        case speakingFallback
    }

    // MARK: - Published state

    /// `true` while an utterance is playing (Kokoro or fallback).
    @Published private(set) var isSpeaking = false

    /// Fine-grained status, including the "preparing voice" loading window.
    @Published private(set) var status: Status = .idle

    // MARK: - Private — Kokoro

    /// The Kokoro 82M ANE actor. Created lazily on the first `speak(_:)`.
    private var kokoroManager: KokoroAneManager?

    /// Set to `true` after the first successful `KokoroAneManager.initialize()`
    /// so we don't call it again on every utterance.
    private var kokoroReady = false

    /// Serialises overlapping `speak()` calls so we never have two async tasks
    /// both touching `kokoroManager` at once.
    private var activeSpeechTask: Task<Void, Never>?

    /// `AVAudioPlayer` for the WAV data returned by Kokoro.
    private var audioPlayer: AVAudioPlayer?

    /// Temp file used to pass WAV bytes to `AVAudioPlayer`; recreated for
    /// every utterance.
    private var tempWavURL: URL?

    // MARK: - Private — Fallback (AVSpeechSynthesizer)

    private var fallbackSynthesizer: AVSpeechSynthesizer?

    // MARK: - Public API

    /// Speak `text` aloud using Kokoro-82M on-device TTS.
    ///
    /// If Kokoro is not yet initialized the model is downloaded / loaded in
    /// the background and a `"preparing voice…"` status is published. Any
    /// error (offline, simulator CoreML failure, etc.) silently falls back to
    /// `AVSpeechSynthesizer`.
    ///
    /// If already speaking, the prior utterance is stopped immediately before
    /// the new one begins.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any in-flight synthesis task and stop current playback.
        activeSpeechTask?.cancel()
        stopAudioPlayer()
        stopFallbackSynthesizer()

        activeSpeechTask = Task { [weak self] in
            await self?.performSpeak(trimmed)
        }
    }

    /// Interrupt any in-progress speech immediately.
    func stop() {
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        stopAudioPlayer()
        stopFallbackSynthesizer()
        isSpeaking = false
        status = .idle
    }

    // MARK: - Private — Kokoro synthesis path

    /// Main synthesis coroutine. Runs under a `Task`, so it is cancellable.
    private func performSpeak(_ text: String) async {
        do {
            let manager = ensureKokoroManager()

            // Initialize (download) Kokoro models the first time — this is a
            // no-op on subsequent calls once `kokoroReady` is true.
            if !kokoroReady {
                status = .preparingVoice
                try await manager.initialize()
                kokoroReady = true
            }

            try Task.checkCancellation()

            status = .speaking
            isSpeaking = true

            // Synthesize: returns 24 kHz mono 16-bit PCM WAV Data.
            let wavData = try await manager.synthesize(
                text: text,
                voice: KokoroAneConstants.defaultVoice, // "af_heart" — natural English
                speed: KokoroAneConstants.defaultSpeed   // 1.0×
            )

            try Task.checkCancellation()

            try playWAV(wavData)

        } catch is CancellationError {
            // Task was cancelled (e.g. stop() was called) — leave state as-is;
            // stop() already reset isSpeaking / status.
            return
        } catch {
            // Kokoro failed (offline, simulator CoreML, etc.) — fall back.
            await performFallback(text)
        }
    }

    /// Lazy-create the Kokoro actor (no init work happens here).
    private func ensureKokoroManager() -> KokoroAneManager {
        if let mgr = kokoroManager { return mgr }
        let mgr = KokoroAneManager(variant: .english)
        kokoroManager = mgr
        return mgr
    }

    /// Write WAV bytes to a temp file and hand to `AVAudioPlayer`.
    private func playWAV(_ data: Data) throws {
        // Reuse the same temp path; AVAudioPlayer holds a reference to the URL
        // so we must not delete the file while it is open — we overwrite it
        // instead (always closed before this point).
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inbox_tts_kokoro.wav")
        try data.write(to: url, options: .atomic)
        tempWavURL = url

        configureAudioSession()

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        player.play()
        // isSpeaking / status already set before this call.
    }

    private func stopAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Private — Fallback synthesis (AVSpeechSynthesizer)

    /// Speak `text` via `AVSpeechSynthesizer` — used when Kokoro is
    /// unavailable (offline, CoreML failure on simulator, etc.).
    private func performFallback(_ text: String) async {
        guard !Task.isCancelled else { return }

        status = .speakingFallback
        isSpeaking = true

        let synth = ensureFallbackSynthesizer()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        configureAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        if let code = AVSpeechSynthesisVoice.currentLanguageCode() as String?,
           let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    private func ensureFallbackSynthesizer() -> AVSpeechSynthesizer {
        if let s = fallbackSynthesizer { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        fallbackSynthesizer = s
        return s
    }

    private func stopFallbackSynthesizer() {
        fallbackSynthesizer?.stopSpeaking(at: .immediate)
    }

    // MARK: - Audio session helpers

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - AVAudioPlayerDelegate (Kokoro playback completion)

extension InboxVoiceTTS: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                  successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
            self.status = .idle
            self.deactivateAudioSession()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,
                                                     error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
            self.status = .idle
            self.deactivateAudioSession()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate (fallback completion)

extension InboxVoiceTTS: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.status = .idle
            self.deactivateAudioSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.status = .idle
        }
    }
}
