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
    /// What SenseVoice makes of breaths and music, compared case-insensitively.
    static let noiseTexts: Set<String> = ["", ".", "the."]

    /// Seconds of audio kept on each side of a decoding window. VAD onsets
    /// often land just after the first syllable; decoding the bare range
    /// clipped it (包括识别 came out as 过识别/或识别 in 6 of 8 test runs, 0 of 8
    /// with this padding).
    static let decodePadding = 0.25

    /// Speech ranges separated by less than this many seconds are decoded
    /// together, up to `maxWindow` seconds per window. Whole sentences give the
    /// model context: on a test file 字母→字幕 went from 0/8 to 7/8 correct and
    /// 简映→剪映 from 0/8 to 3/8. Subtitle lines are cut afterwards using the
    /// per-token timestamps (see SubtitleLayout).
    static let mergeGap = 0.6
    static let maxWindow = 20.0

    /// Seconds of silence fed after the audio before flushing, so speech that
    /// runs right up to the end of the file is still closed off and emitted
    /// (a 0.54 s clip ending mid-word otherwise produced no segment at all).
    static let tailSilence = 0.5

    /// Share of the progress bar given to the VAD pass; decoding is the rest
    /// (VAD measured at ~20% of total time).
    static let vadProgressShare = 0.2

    /// Transcribe 16kHz mono samples into timed tokens, grouped by decoding
    /// window; turn them into subtitle lines with `SubtitleLayout`.
    /// `onProgress` receives a 0...1 fraction (VAD pass, then decoding).
    /// `shouldCancel` is polled between VAD windows and between decodes;
    /// returning true aborts with CancellationError.
    public static func transcribe(
        samples: [Float],
        models: ModelPaths,
        language: String = "",
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> RawTranscript {
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

        // Pass 2: merge nearby ranges into windows and decode each with padding.
        let windows = mergedRanges(
            speech, maxGap: Int(mergeGap * sampleRate), maxLength: Int(maxWindow * sampleRate))
        let decodeRanges = paddedRanges(
            windows, total: samples.count, padding: Int(decodePadding * sampleRate))
        let totalSpeech = max(windows.reduce(0) { $0 + $1.count }, 1)
        var decoded = 0
        var transcript: [TranscriptWindow] = []
        for (range, decodeRange) in zip(windows, decodeRanges) {
            if shouldCancel?() == true { throw CancellationError() }
            let recognition = recognizer.recognize(samples: samples[decodeRange])
            let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !noiseTexts.contains(text.lowercased()) {
                let start = Double(range.lowerBound) / sampleRate
                let end = Double(range.upperBound) / sampleRate
                transcript.append(
                    TranscriptWindow(
                        start: start, end: end,
                        tokens: timedTokens(
                            recognition, offset: Double(decodeRange.lowerBound) / sampleRate,
                            start: start, end: end)))
            }
            decoded += range.count
            progress.report(
                vadProgressShare + (1 - vadProgressShare) * Double(decoded) / Double(totalSpeech))
        }
        progress.report(1)

        return RawTranscript(windows: transcript)
    }

    /// Absolute token times. Models without timestamps get their tokens spread
    /// evenly over the window, which keeps line timing roughly right.
    static func timedTokens(
        _ recognition: Recognition, offset: Double, start: Double, end: Double
    ) -> [TimedToken] {
        let tokens = recognition.tokens
        guard !tokens.isEmpty else {
            return recognition.text.isEmpty ? [] : [TimedToken(text: recognition.text, time: start)]
        }
        if recognition.timestamps.count == tokens.count {
            return zip(tokens, recognition.timestamps).map {
                TimedToken(text: $0, time: offset + Double($1))
            }
        }
        let step = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { TimedToken(text: $1, time: start + Double($0) * step) }
    }

    /// Joins speech ranges less than `maxGap` samples apart into one decoding
    /// window, as long as the window stays within `maxLength` samples.
    static func mergedRanges(_ ranges: [Range<Int>], maxGap: Int, maxLength: Int) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound - last.upperBound < maxGap,
                range.upperBound - last.lowerBound <= maxLength
            {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
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
