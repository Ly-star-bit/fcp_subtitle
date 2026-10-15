import Foundation

/// Display-timing clean-up following common subtitle practice (Netflix timed
/// text guidelines): a line stays up long enough to read and a little past
/// its speech, and lines either touch (two frames apart) or leave a clear
/// gap — short gaps make subtitles flicker off and on between sentences.
public struct TimingRules: Equatable, Sendable {
    /// Shortest time a line is shown.
    public var minDuration = 0.8
    /// Gap kept between consecutive lines (two frames).
    public var minGap: Double
    /// Gaps shorter than this are closed down to `minGap`.
    public var chainGap = 0.5
    /// How long a line may linger after its speech when nothing follows soon.
    public var tail = 0.5

    public init(frameDuration: Double) {
        minGap = 2 * frameDuration
    }

    public func apply(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        var lines = segments.sorted { $0.start < $1.start }
        for i in lines.indices {
            let start = lines[i].start
            let nextStart = i + 1 < lines.count ? lines[i + 1].start : .infinity
            let limit = nextStart - minGap
            var end = max(lines[i].end + tail, start + minDuration)
            if nextStart - end < chainGap { end = limit }
            end = min(end, limit)
            // Never shorter than a frame-ish sliver, even when the next line
            // starts almost immediately; FCPXML export resolves the overlap.
            lines[i].duration = max(end - start, 0.04)
        }
        return lines
    }
}
