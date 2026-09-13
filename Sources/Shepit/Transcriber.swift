import Foundation
import WhisperKit

actor Transcriber {
    /// Quantized Core ML build of whisper-large-v3-turbo from argmaxinc/whisperkit-coreml.
    static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var whisper: WhisperKit?

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
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
}
