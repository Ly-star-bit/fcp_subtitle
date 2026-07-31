import Foundation

/// Splits over-long subtitle lines into readable chunks.
///
/// The VAD produces segments up to ~5s that often contain several sentences.
/// We split on punctuation, greedily pack clauses up to `maxChars`, and allocate
/// each chunk a share of the segment's time proportional to its character count.
public enum SegmentSplitter {
    static let clauseSeparators: Set<Character> = [
        "。", "，", "？", "！", "；", "、", ",", ".", "?", "!", ";",
    ]

    public static func split(_ segments: [SubtitleSegment], maxChars: Int) -> [SubtitleSegment] {
        guard maxChars > 0 else { return segments }
        return segments.flatMap { splitOne($0, maxChars: maxChars) }
    }

    static func splitOne(_ seg: SubtitleSegment, maxChars: Int) -> [SubtitleSegment] {
        guard seg.text.count > maxChars else { return [seg] }

        var clauses: [String] = []
        var current = ""
        for ch in seg.text {
            current.append(ch)
            if clauseSeparators.contains(ch) {
                clauses.append(current)
                current = ""
            }
        }
        if !current.isEmpty { clauses.append(current) }

        // Greedily pack clauses into chunks of at most maxChars.
        var chunks: [String] = []
        var buffer = ""
        for clause in clauses {
            if buffer.isEmpty {
                buffer = clause
            } else if buffer.count + clause.count <= maxChars {
                buffer += clause
            } else {
                chunks.append(buffer)
                buffer = clause
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }

        // Hard-split any single clause still longer than maxChars.
        var pieces: [String] = []
        for chunk in chunks {
            if chunk.count <= maxChars {
                pieces.append(chunk)
            } else {
                var rest = Substring(chunk)
                while rest.count > maxChars {
                    pieces.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
                if !rest.isEmpty { pieces.append(String(rest)) }
            }
        }

        let cleaned = pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard cleaned.count > 1 else { return [seg] }

        let totalChars = cleaned.reduce(0) { $0 + $1.count }
        var cursor = seg.start
        var result: [SubtitleSegment] = []
        for (index, text) in cleaned.enumerated() {
            let duration: Double
            if index == cleaned.count - 1 {
                duration = seg.end - cursor
            } else {
                duration = seg.duration * Double(text.count) / Double(totalChars)
            }
            result.append(SubtitleSegment(start: cursor, duration: duration, text: text))
            cursor += duration
        }
        return result
    }
}
