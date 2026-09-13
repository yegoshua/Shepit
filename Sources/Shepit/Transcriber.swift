import Foundation
import ShepitCore
import WhisperKit

actor Transcriber {
    /// Quantized Core ML build of whisper-large-v3-turbo from argmaxinc/whisperkit-coreml.
    static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var whisper: WhisperKit?
    private var loadFailed = false
    /// The actor is reentrant across awaits, so this keeps dictation and meeting
    /// transcriptions from running on the same WhisperKit instance at once.
    private var isBusy = false

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        loadFailed = false
        do {
            try await loadModel(progress: progress)
        } catch {
            loadFailed = true
            throw error
        }
    }

    /// Suspends while the model is still loading; false if loading failed.
    func waitUntilLoaded() async -> Bool {
        while whisper == nil && !loadFailed {
            try? await Task.sleep(for: .seconds(1))
        }
        return whisper != nil
    }

    private func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = try await WhisperKit.download(variant: Self.modelName) { p in
            progress(p.fractionCompleted)
        }
        Log.info("model files ready at \(folder.path)")
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let whisper else { return "" }
        await acquire()
        defer { isBusy = false }
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func acquire() async {
        while isBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        isBusy = true
    }

    /// Transcribes a long recording, streaming it from disk in chunks instead of loading it
    /// whole, and returns timestamped segments with the language Whisper used.
    func transcribeFile(at url: URL, language: String?) async throws -> (segments: [TranscriptSegment], language: String) {
        guard let whisper else { throw TranscriberError.modelNotLoaded }
        await acquire()
        defer { isBusy = false }
        let options = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        let results = try await whisper.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options
        )
        let segments = results
            .flatMap(\.segments)
            .map { TranscriptSegment(start: TimeInterval($0.start), end: TimeInterval($0.end), text: $0.text) }
            .sorted { $0.start < $1.start }
        return (segments, results.first?.language ?? language ?? "auto")
    }
}

enum TranscriberError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? { "модель ще не завантажена" }
}
