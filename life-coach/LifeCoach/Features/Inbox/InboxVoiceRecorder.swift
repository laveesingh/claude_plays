import Foundation
import AVFoundation

/// Microphone capture for the "Ask your inbox" voice layer. Records to a
/// temporary `.m4a` file using `AVAudioEngine`, then returns the file URL
/// when `stop()` is called. Publishes a normalized 0…1 audio level so the UI
/// can animate a simple waveform indicator while recording.
///
/// `AVAudioSession` is configured for `.playAndRecord` with `.defaultToSpeaker`
/// so playback (TTS) works in the same session. Mic permission is requested via
/// `AVAudioApplication.requestRecordPermission` (iOS 17 API).
///
/// House notes:
/// - `start()` / `stop()` must be called from the main actor (they publish).
/// - The temp file lives at `InboxVoiceRecorder.tempFileURL`; each call to
///   `start()` overwrites it, so the caller should copy/move the URL if needed.
@MainActor
final class InboxVoiceRecorder: ObservableObject {

    // MARK: - Published state

    /// True while the audio engine is running and writing audio.
    @Published private(set) var isRecording = false

    /// Normalized 0…1 loudness of the most recent buffer, suitable for a
    /// level-bar or waveform indicator.
    @Published private(set) var audioLevel: Float = 0

    // MARK: - Private

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    /// The URL of the temp file that `stop()` returns.
    static let tempFileURL: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox_voice_query.m4a")
    }()

    // MARK: - Public API

    /// Request mic permission (if not already granted) and begin recording.
    ///
    /// Returns `false` if the user has denied microphone access. On success,
    /// sets `isRecording = true` and starts publishing `audioLevel` updates.
    @discardableResult
    func start() async -> Bool {
        // iOS 17 API for requesting mic permission.
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return false }

        do {
            try configureSession()
            try startEngine()
            isRecording = true
            return true
        } catch {
            isRecording = false
            return false
        }
    }

    /// Stop recording and return the URL of the captured audio file. Returns
    /// `nil` if recording was never started or the file write failed.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRecording = false
        audioLevel = 0

        // Deactivate record session so TTS playback can take over.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])

        return Self.tempFileURL
    }

    // MARK: - Session + engine setup

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])
    }

    private func startEngine() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Build a settings dict for the m4a output file.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        // Overwrite any previous temp recording.
        let fileURL = Self.tempFileURL
        try? FileManager.default.removeItem(at: fileURL)
        let avFile = try AVAudioFile(forWriting: fileURL,
                                     settings: outputSettings,
                                     commonFormat: inputFormat.commonFormat,
                                     interleaved: true)
        file = avFile

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Write compressed audio; ignore individual buffer write errors.
            try? avFile.write(from: buffer)
            // Publish level to main actor.
            let level = buffer.averagePower()
            Task { @MainActor in self.audioLevel = level }
        }

        engine.prepare()
        try engine.start()
    }
}
