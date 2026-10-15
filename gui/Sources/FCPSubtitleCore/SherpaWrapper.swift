import Foundation
import SherpaOnnxC

/// Minimal Swift bindings over the sherpa-onnx C API, covering only what this
/// app needs: a SenseVoice offline recognizer and a Silero voice activity
/// detector. C config structs are zero-initialized and assigned field by field,
/// with C-string copies kept alive for the duration of the create call.
private final class CStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func cstr(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        pointers.append(p)
        return UnsafePointer(p)
    }

    deinit {
        for p in pointers { free(p) }
    }
}

/// One decode's output: the text plus its tokens, each with a start time in
/// seconds from the beginning of the decoded audio. `timestamps` is empty when
/// the model doesn't provide them.
public struct Recognition: Sendable {
    public let text: String
    public let tokens: [String]
    public let timestamps: [Float]
}

public final class SenseVoiceRecognizer {
    private let recognizer: OpaquePointer

    /// `language`: "" or "auto" for auto-detect, or one of zh/en/ja/ko/yue.
    public init(modelPath: String, tokensPath: String, numThreads: Int = 4, language: String = "") throws {
        let arena = CStringArena()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = arena.cstr(modelPath)
        config.model_config.sense_voice.language = arena.cstr(language == "auto" ? "" : language)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = arena.cstr(tokensPath)
        config.model_config.num_threads = Int32(numThreads)
        config.model_config.provider = arena.cstr("cpu")
        config.decoding_method = arena.cstr("greedy_search")

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw NSError(
                domain: "FCPSubtitle", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法加载 SenseVoice 模型: \(modelPath)"])
        }
        recognizer = r
        withExtendedLifetime(arena) {}
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Decodes a slice in place, so callers can hand over a range of a long
    /// recording without copying it out first.
    public func recognize(samples: ArraySlice<Float>, sampleRate: Int = 16000) -> Recognition {
        let empty = Recognition(text: "", tokens: [], timestamps: [])
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return empty }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return empty }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let r = result.pointee
        let count = Int(r.count)
        var tokens: [String] = []
        var timestamps: [Float] = []
        if count > 0, let array = r.tokens_arr {
            tokens = (0..<count).map { array[$0].map { String(cString: $0) } ?? "" }
            if let times = r.timestamps {
                timestamps = Array(UnsafeBufferPointer(start: times, count: count))
            }
        }
        return Recognition(
            text: r.text.map { String(cString: $0) } ?? "", tokens: tokens, timestamps: timestamps)
    }
}

public final class SileroVad {
    private let vad: OpaquePointer
    public let windowSize: Int

    public init(
        modelPath: String,
        threshold: Float = 0.2,
        minSilenceDuration: Float = 0.25,
        minSpeechDuration: Float = 0.25,
        maxSpeechDuration: Float = 5.0,
        sampleRate: Int = 16000,
        bufferSizeInSeconds: Float = 120
    ) throws {
        let arena = CStringArena()
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = arena.cstr(modelPath)
        config.silero_vad.threshold = threshold
        config.silero_vad.min_silence_duration = minSilenceDuration
        config.silero_vad.min_speech_duration = minSpeechDuration
        config.silero_vad.max_speech_duration = maxSpeechDuration
        config.silero_vad.window_size = 512
        config.sample_rate = Int32(sampleRate)
        config.num_threads = 1
        config.provider = arena.cstr("cpu")

        windowSize = 512
        guard let v = SherpaOnnxCreateVoiceActivityDetector(&config, bufferSizeInSeconds) else {
            throw NSError(
                domain: "FCPSubtitle", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法加载 VAD 模型: \(modelPath)"])
        }
        vad = v
        withExtendedLifetime(arena) {}
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }

    public func acceptWaveform(_ samples: ArraySlice<Float>) {
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress, Int32(buf.count))
        }
    }

    public func flush() {
        SherpaOnnxVoiceActivityDetectorFlush(vad)
    }

    public var isEmpty: Bool {
        SherpaOnnxVoiceActivityDetectorEmpty(vad) == 1
    }

    /// Pops the front finished segment as a range of sample indices into the
    /// stream fed so far. The segment's own sample copy is not needed: callers
    /// slice the original recording, which also lets them widen the range.
    public func popFrontRange() -> Range<Int>? {
        guard !isEmpty, let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { return nil }
        defer {
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        let start = Int(seg.pointee.start)
        return start..<(start + Int(seg.pointee.n))
    }
}
