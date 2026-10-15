import Foundation

/// VAD + SenseVoice transcription pipeline, following sherpa-onnx's official
/// generate-subtitles example: feed the VAD in window-size chunks and flush to
/// find speech ranges, then decode each range. Ranges are decoded with a little
/// surrounding audio (see `decodePadding`) but timed by the VAD boundaries.
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

    /// Seconds of audio kept on each side of a speech range when decoding.
    /// VAD onsets often land just after the first syllable; decoding the bare
    /// range clipped it (包括识别 came out as 过识别/或识别 in 6 of 8 test runs,
    /// 0 of 8 with this padding).
    static let decodePadding = 0.25

    /// Seconds of silence fed after the audio before flushing, so speech that
    /// runs right up to the end of the file is still closed off and emitted
    /// (a 0.54 s clip ending mid-word otherwise produced no segment at all).
    static let tailSilence = 0.5

    /// Share of the progress bar given to the VAD pass; decoding is the rest
    /// (VAD measured at ~20% of total time).
    static let vadProgressShare = 0.2

    /// Transcribe 16kHz mono samples into timed subtitle segments.
    /// `onProgress` receives a 0...1 fraction (VAD pass, then decoding).
    /// `shouldCancel` is polled between VAD windows and between decodes;
    /// returning true aborts with CancellationError.
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
        var progress = ProgressThrottle(onProgress)

        // Pass 1: find speech ranges. A range may reach into the appended
        // silence, so clamp it to the real audio.
        var speech: [Range<Int>] = []
        func collect() {
            while let range = vad.popFrontRange() {
                let clamped = range.clamped(to: 0..<samples.count)
                if !clamped.isEmpty { speech.append(clamped) }
            }
        }

        var offset = 0
        while offset < samples.count {
            if shouldCancel?() == true { throw CancellationError() }
            let end = min(offset + window, samples.count)
            vad.acceptWaveform(samples[offset..<end])
            offset = end
            collect()
            progress.report(vadProgressShare * Double(offset) / Double(samples.count))
        }
        let silence = [Float](repeating: 0, count: Int(tailSilence * sampleRate))
        for start in stride(from: 0, to: silence.count, by: window) {
            vad.acceptWaveform(silence[start..<min(start + window, silence.count)])
        }
        vad.flush()
        collect()

        // Pass 2: decode each range with its padding; time it by the VAD range.
        let decodeRanges = paddedRanges(
            speech, total: samples.count, padding: Int(decodePadding * sampleRate))
        let totalSpeech = max(speech.reduce(0) { $0 + $1.count }, 1)
        var decoded = 0
        var segments: [SubtitleSegment] = []
        for (range, decodeRange) in zip(speech, decodeRanges) {
            if shouldCancel?() == true { throw CancellationError() }
            let text = recognizer.decode(samples: samples[decodeRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !noiseTexts.contains(text) {
                segments.append(
                    SubtitleSegment(
                        start: Double(range.lowerBound) / sampleRate,
                        duration: Double(range.count) / sampleRate,
                        text: text))
            }
            decoded += range.count
            progress.report(
                vadProgressShare + (1 - vadProgressShare) * Double(decoded) / Double(totalSpeech))
        }
        progress.report(1)

        return segments
    }

    /// Widens each speech range by up to `padding` samples per side for
    /// decoding. Between two ranges each side gets at most half the gap, so no
    /// audio is decoded twice; the outer edges stop at 0 and `total`.
    static func paddedRanges(_ ranges: [Range<Int>], total: Int, padding: Int) -> [Range<Int>] {
        ranges.indices.map { i in
            let range = ranges[i]
            let room = (
                before: i > 0 ? (range.lowerBound - ranges[i - 1].upperBound) / 2 : range.lowerBound,
                after: i + 1 < ranges.count
                    ? (ranges[i + 1].lowerBound - range.upperBound) / 2 : total - range.upperBound
            )
            let before = min(padding, max(room.before, 0))
            let after = min(padding, max(room.after, 0))
            return (range.lowerBound - before)..<(range.upperBound + after)
        }
    }
}
