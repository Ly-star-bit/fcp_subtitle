import Foundation

/// All subtitle export formats. FCPXML has its own dedicated builder
/// (frame-accurate rational times); the rest are simple text serializers.
public enum SubtitleFormat: String, CaseIterable, Sendable {
    case fcpxml
    case srt
    case vtt
    case ass
    case lrc
    case txt

    public var displayName: String {
        switch self {
        case .fcpxml: return "FCPXML (Final Cut Pro)"
        case .srt: return "SRT (PR/达芬奇/剪映)"
        case .vtt: return "WebVTT (网页/YouTube)"
        case .ass: return "ASS (高级样式/压制)"
        case .lrc: return "LRC (歌词)"
        case .txt: return "纯文本 (文字稿)"
        }
    }

    public var fileExtension: String { rawValue == "fcpxml" ? "fcpxml" : rawValue }
}

public enum SubtitleExporter {
    /// Serialize segments to the given format. FCPXML honors fps/size/font
    /// settings; ASS embeds size and font as its script resolution and default
    /// style; others ignore styling. Throws only for an unsupported FCPXML fps.
    public static func export(
        segments: [SubtitleSegment],
        format: SubtitleFormat,
        fps: String = "25",
        width: Int = 1920,
        height: Int = 1080,
        font: String = "PingFang SC",
        fontSize: Int = 60
    ) throws -> String {
        let ordered = segments.sorted { $0.start < $1.start }
        switch format {
        case .fcpxml:
            return try FCPXMLBuilder.build(
                segments: ordered, fps: fps, width: width, height: height,
                font: font, fontSize: fontSize)
        case .srt:
            return SRTBuilder.build(segments: ordered)
        case .vtt:
            return buildVTT(ordered)
        case .ass:
            return buildASS(ordered, width: width, height: height, font: font, fontSize: fontSize)
        case .lrc:
            return buildLRC(ordered)
        case .txt:
            return ordered.map(\.text).joined(separator: "\n") + "\n"
        }
    }

    // MARK: - WebVTT

    private static func buildVTT(_ segments: [SubtitleSegment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            out += "\(vttTime(seg.start)) --> \(vttTime(seg.end))\n\(seg.text)\n\n"
        }
        return out
    }

    private static func vttTime(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            totalMs / 3_600_000, totalMs / 60_000 % 60, totalMs / 1000 % 60, totalMs % 1000)
    }

    // MARK: - ASS

    private static func buildASS(
        _ segments: [SubtitleSegment], width: Int, height: Int, font: String, fontSize: Int
    ) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 0

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(font),\(fontSize),&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,60,60,50,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for seg in segments {
            let text = seg.text.replacingOccurrences(of: "\n", with: "\\N")
            out += "Dialogue: 0,\(assTime(seg.start)),\(assTime(seg.end)),Default,,0,0,0,,\(text)\n"
        }
        return out
    }

    private static func assTime(_ seconds: Double) -> String {
        let totalCs = Int((seconds * 100).rounded())
        return String(
            format: "%d:%02d:%02d.%02d",
            totalCs / 360_000, totalCs / 6000 % 60, totalCs / 100 % 60, totalCs % 100)
    }

    // MARK: - LRC

    private static func buildLRC(_ segments: [SubtitleSegment]) -> String {
        var out = ""
        for seg in segments {
            let totalCs = Int((seg.start * 100).rounded())
            let stamp = String(
                format: "[%02d:%02d.%02d]", totalCs / 6000, totalCs / 100 % 60, totalCs % 100)
            out += "\(stamp)\(seg.text)\n"
        }
        return out
    }
}
