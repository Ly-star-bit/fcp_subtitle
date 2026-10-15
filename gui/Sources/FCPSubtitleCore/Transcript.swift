import Foundation

/// One recognized token and when it starts, in seconds from the start of the file.
public struct TimedToken: Codable, Equatable, Sendable {
    public var text: String
    public var time: Double

    public init(text: String, time: Double) {
        self.text = text
        self.time = time
    }
}

/// A stretch of speech decoded in one pass: its VAD bounds and its tokens.
public struct TranscriptWindow: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var tokens: [TimedToken]

    public init(start: Double, end: Double, tokens: [TimedToken]) {
        self.start = start
        self.end = end
        self.tokens = tokens
    }
}

/// Everything recognition produced. Kept alongside the subtitles so they can be
/// re-split with other line-length, punctuation or timing settings without
/// running speech recognition again.
public struct RawTranscript: Codable, Equatable, Sendable {
    public var windows: [TranscriptWindow]

    public init(windows: [TranscriptWindow]) {
        self.windows = windows
    }
}
