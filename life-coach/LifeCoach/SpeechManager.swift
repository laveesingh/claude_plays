import Foundation
import AVFoundation
import Speech

enum VoiceError: LocalizedError {
    case unavailable
    case localeNotSupported
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "On-device speech recognition isn't available on this device."
        case .localeNotSupported: return "Your language isn't supported for on-device transcription yet."
        case .conversionFailed: return "Audio conversion failed."
        }
    }
}

// MARK: - Audio helpers

extension AVAudioPCMBuffer {
    /// Normalised 0...1 loudness for the waveform, on a rough dB scale.
    func averagePower() -> Float {
        guard let channel = floatChannelData?[0] else { return 0 }
        let count = Int(frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))      // ~ -120 (silence) ... 0 (full)
        let normalised = (db + 50) / 50          // map -50dB..0dB -> 0..1
        return min(max(normalised, 0), 1)
    }
}

// MARK: - iOS 26 SpeechAnalyzer engine

@available(iOS 26.0, *)
final class SpeechAnalyzerEngine {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var reservedLocale: Locale?

    static func resolveLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let ids = supported.map { $0.identifier(.bcp47) }
        let current = Locale.current.identifier(.bcp47)
        if ids.contains(current) { return Locale.current }
        if let english = supported.first(where: { $0.identifier(.bcp47).hasPrefix("en") }) { return english }
        return supported.first
    }

    func start(locale: Locale,
               onPartial: @escaping (String) -> Void,
               onLevel: @escaping (Float) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        self.transcriber = transcriber

        // Download the on-device model for this locale if it isn't present yet.
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
        try await AssetInventory.reserve(locale: locale)
        reservedLocale = locale

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        // Accumulate finalised segments; show the latest volatile segment live.
        resultsTask = Task {
            var finalised = ""
            do {
                for try await result in transcriber.results {
                    let chunk = String(result.text.characters)
                    if result.isFinal {
                        finalised += (finalised.isEmpty ? "" : " ") + chunk
                        onPartial(finalised)
                    } else {
                        onPartial(finalised.isEmpty ? chunk : finalised + " " + chunk)
                    }
                }
            } catch {
                // Stream ended or was cancelled; nothing more to surface.
            }
        }

        try await analyzer.start(inputSequence: stream)

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if let analyzerFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            onLevel(buffer.averagePower())
            guard let analyzerFormat = self.analyzerFormat, let converter = self.converter else { return }
            if let converted = try? Self.convert(buffer, using: converter, to: analyzerFormat) {
                self.inputBuilder?.yield(AnalyzerInput(buffer: converted))
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
        }
        analyzer = nil
        transcriber = nil
        converter = nil
        reservedLocale = nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            throw VoiceError.conversionFailed
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }
}

// MARK: - Legacy SFSpeechRecognizer engine (iOS < 26, on-device)

final class LegacySpeechEngine {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(onPartial: @escaping (String) -> Void,
               onLevel: @escaping (Float) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onLevel(buffer.averagePower())
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { result, _ in
            if let result {
                onPartial(result.bestTranscription.formattedString)
            }
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}

// MARK: - VoiceController (drives the voice-input sheet)

@MainActor
final class VoiceController: ObservableObject {
    static let barCount = 42

    @Published var transcript = ""
    @Published var isRecording = false
    @Published var levels: [CGFloat] = Array(repeating: 0.04, count: VoiceController.barCount)
    @Published var statusMessage: String?

    private var analyzerEngine: Any?
    private var legacyEngine: LegacySpeechEngine?

    func start() async {
        transcript = ""
        statusMessage = nil
        resetLevels()

        guard await requestPermissions() else {
            statusMessage = "Allow microphone and speech access in Settings to talk."
            return
        }
        do {
            try configureSession()
            if #available(iOS 26.0, *) {
                let engine = SpeechAnalyzerEngine()
                analyzerEngine = engine
                guard let locale = await SpeechAnalyzerEngine.resolveLocale() else {
                    throw VoiceError.localeNotSupported
                }
                try await engine.start(locale: locale,
                                       onPartial: { [weak self] text in
                                           Task { @MainActor in self?.transcript = text }
                                       },
                                       onLevel: { [weak self] level in
                                           Task { @MainActor in self?.push(level) }
                                       })
            } else {
                let engine = LegacySpeechEngine()
                legacyEngine = engine
                try engine.start(onPartial: { [weak self] text in
                                     Task { @MainActor in self?.transcript = text }
                                 },
                                 onLevel: { [weak self] level in
                                     Task { @MainActor in self?.push(level) }
                                 })
            }
            isRecording = true
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't start voice input."
            isRecording = false
            await teardownEngines()
        }
    }

    func stop() async {
        await teardownEngines()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func teardownEngines() async {
        if #available(iOS 26.0, *), let engine = analyzerEngine as? SpeechAnalyzerEngine {
            await engine.stop()
        }
        legacyEngine?.stop()
        analyzerEngine = nil
        legacyEngine = nil
    }

    private func push(_ level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(max(0.04, level)))
    }

    private func resetLevels() {
        levels = Array(repeating: 0.04, count: Self.barCount)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])
    }

    private func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard mic else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return speech
    }
}

// MARK: - Text-to-speech (coach reads a reply aloud, on demand)

@MainActor
final class SpeechSynth: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speakingMessageID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ message: ChatMessage) {
        if speakingMessageID == message.id {
            stop()
        } else {
            speak(message)
        }
    }

    func speak(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        if let code = AVSpeechSynthesisVoice.currentLanguageCode() as String?,
           let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageID = message.id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingMessageID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingMessageID = nil }
    }
}
