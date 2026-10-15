import Foundation

/// Parses .srt files so existing subtitles can be edited and re-exported
/// to any supported format (e.g. 剪映-exported SRT → editable FCPXML).
public enum SRTParser {
    public enum ReadError: LocalizedError {
        case unknownEncoding(String)

        public var errorDescription: String? {
            switch self {
            case .unknownEncoding(let name):
                return "无法识别 \(name) 的文字编码(支持 UTF-8 / UTF-16 / GBK)"
            }
        }
    }

    /// Reads and parses an .srt file in whatever encoding it was saved in.
    public static func parse(contentsOf url: URL) throws -> [SubtitleSegment] {
        let data = try Data(contentsOf: url)
        guard let text = decodeText(data) else {
            throw ReadError.unknownEncoding(url.lastPathComponent)
        }
        return parse(text)
    }

    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// SRT files in the wild are UTF-8, UTF-16 with a BOM (Windows tools), or
    /// GBK/GB18030 (older Chinese tools); strict UTF-8 fails fast on GBK bytes,
    /// so try in that order. Big5 can't be told apart from GBK by decoding
    /// success alone and isn't attempted.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030)
    }

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
