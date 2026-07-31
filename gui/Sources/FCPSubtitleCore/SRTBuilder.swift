import Foundation

/// SRT export for platforms that want plain subtitle files (B站/YouTube uploads).
public enum SRTBuilder {
    public static func build(segments: [SubtitleSegment]) -> String {
        let ordered = segments.sorted { $0.start < $1.start }
        var blocks: [String] = []
        for (index, seg) in ordered.enumerated() {
            blocks.append("\(index + 1)\n\(timestamp(seg.start)) --> \(timestamp(seg.end))\n\(seg.text)\n")
        }
        return blocks.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = totalMs / 60_000 % 60
        let s = totalMs / 1000 % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
