import Foundation

/// VAD + SenseVoice transcription pipeline. Port of src/fcp_subtitle/asr.py,
/// following sherpa-onnx's official generate-subtitles example: feed the VAD in
/// window-size chunks, flush, then pop finished segments and decode each one.
public struct ModelPaths: Sendable {
    public let senseVoiceModel: String
    public let tokens: String
    public let sileroVad: String

    public init(senseVoiceModel: String, tokens: String, sileroVad: String) {
        self.senseVoiceModel = senseVoiceModel
        self.tokens = tokens
        self.sileroVad = sileroVad
    }

    public func validate() throws {
        for path in [senseVoiceModel, tokens, sileroVad] where !FileManager.default.fileExists(atPath: path) {
            throw NSError(
                domain: "FCPSubtitle", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "缺少模型文件: \(path)"])
        }
    }
}

public enum Transcriber {
    static let noiseTexts: Set<String> = ["", ".", "The."]

    /// Transcribe 16kHz mono samples into timed subtitle segments.
    /// `onProgress` receives a 0...1 fraction of samples fed to the VAD.
    /// `shouldCancel` is polled between VAD windows; returning true aborts with CancellationError.
    public static func transcribe(
        samples: [Float],
        models: ModelPaths,
        language: String = "",
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> [SubtitleSegment] {
        try models.validate()
        let recognizer = try SenseVoiceRecognizer(
            modelPath: models.senseVoiceModel, tokensPath: models.tokens, language: language)
        let vad = try SileroVad(modelPath: models.sileroVad)

        let sampleRate = Double(AudioDecoder.sampleRate)
        let window = vad.windowSize
        var segments: [SubtitleSegment] = []

        func drain() {
            while let (startSample, segSamples) = vad.popFront() {
                let text = recognizer.decode(samples: segSamples)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !noiseTexts.contains(text) else { continue }
                segments.append(
                    SubtitleSegment(
                        start: Double(startSample) / sampleRate,
                        duration: Double(segSamples.count) / sampleRate,
                        text: text))
            }
        }

        var offset = 0
        while offset < samples.count {
            if shouldCancel?() == true { throw CancellationError() }
            let end = min(offset + window, samples.count)
            vad.acceptWaveform(Array(samples[offset..<end]))
            offset = end
            drain()
            onProgress?(Double(offset) / Double(max(samples.count, 1)))
        }
        vad.flush()
        drain()

        return segments
    }
}
