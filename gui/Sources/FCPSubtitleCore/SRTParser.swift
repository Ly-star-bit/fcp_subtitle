import Foundation

/// Parses .srt files so existing subtitles can be edited and re-exported
/// to any supported format (e.g. 剪映-exported SRT → editable FCPXML).
public enum SRTParser {
    public static func parse(_ content: String) -> [SubtitleSegment] {
        var segments: [SubtitleSegment] = []
        // Blocks are separated by blank lines; tolerate \r\n and BOM.
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let parts = lines[timeLineIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                let start = parseTime(parts[0]),
                let end = parseTime(parts[1]),
                end > start
            else { continue }

            let text = lines[(timeLineIndex + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(SubtitleSegment(start: start, duration: end - start, text: text))
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// "00:01:23,456" (or with '.') -> seconds
    static func parseTime(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3,
            let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }
}
