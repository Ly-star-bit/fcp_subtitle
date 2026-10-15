import Foundation

/// A subtitle line with second-based timing and (user-editable) text.
public struct SubtitleSegment: Identifiable, Equatable, Sendable, Codable {
    public var id = UUID()
    public var start: Double
    public var duration: Double
    public var text: String

    public init(start: Double, duration: Double, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }

    public var end: Double { start + duration }
}

/// Frame-accurate FCPXML generation. Port of the verified Python implementation
/// (src/fcp_subtitle/fcpxml.py): rational frame times, explicit gap filling,
/// XML entity escaping, one editable Basic Title per subtitle line.
public enum FCPXMLBuilder {
    public enum BuildError: LocalizedError {
        case unsupportedFrameRate(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFrameRate(let fps):
                return "不支持的帧率 \(fps),可选: \(FCPXMLBuilder.fpsLabels.joined(separator: " / "))"
            }
        }
    }

    public static let basicTitleUID =
        ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

    /// fps label -> frame duration (numerator, denominator), plus the rate
    /// token FCP uses in its standard format names (23.976 is "2398").
    public static let frameDurations: [(label: String, num: Int, den: Int, nameToken: String)] = [
        ("23.976", 1001, 24000, "2398"),
        ("24", 1, 24, "24"),
        ("25", 1, 25, "25"),
        ("29.97", 1001, 30000, "2997"),
        ("30", 1, 30, "30"),
        ("50", 1, 50, "50"),
        ("59.94", 1001, 60000, "5994"),
        ("60", 1, 60, "60"),
    ]

    public static var fpsLabels: [String] { frameDurations.map(\.label) }

    static func frameDuration(forFps fps: String) -> (num: Int, den: Int)? {
        frameDurations.first { $0.label == fps }.map { ($0.num, $0.den) }
    }

    /// Length of one frame in seconds, e.g. 0.04 for "25".
    public static func frameSeconds(fps: String) -> Double? {
        frameDuration(forFps: fps).map { Double($0.num) / Double($0.den) }
    }

    /// The supported label closest to a measured rate (e.g. a video track's
    /// nominal 29.97003), or nil when none is within 1% — 15 fps screen
    /// recordings or 120 fps slow motion fall back to the manual setting.
    public static func fpsLabel(matching rate: Double) -> String? {
        guard rate > 0 else { return nil }
        let nearest = frameDurations.min {
            abs(Double($0.den) / Double($0.num) - rate) < abs(Double($1.den) / Double($1.num) - rate)
        }
        guard let nearest else { return nil }
        let exact = Double(nearest.den) / Double(nearest.num)
        return abs(exact - rate) / exact <= 0.01 ? nearest.label : nil
    }

    /// FCP's own name for standard HD formats. Other sizes (vertical, 4K...)
    /// leave the optional name out and are described by width/height/rate.
    static func formatName(width: Int, height: Int, fps: String) -> String? {
        guard let token = frameDurations.first(where: { $0.label == fps })?.nameToken else {
            return nil
        }
        switch (width, height) {
        case (1920, 1080):
            return "FFVideoFormat1080p\(token)"
        case (1280, 720) where ["2398", "25", "2997", "50", "5994", "60"].contains(token):
            return "FFVideoFormat720p\(token)"
        default:
            return nil
        }
    }

    private static func escapeXML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    private static func quantizeFrames(_ seconds: Double, num: Int, den: Int) -> Int {
        Int((seconds * Double(den) / Double(num)).rounded())
    }

    private static func framesToTime(_ frames: Int, num: Int, den: Int) -> String {
        let totalNum = frames * num
        let g = gcd(totalNum, den)
        let n = totalNum / g
        let d = den / g
        return d == 1 ? "\(n)s" : "\(n)/\(d)s"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    public static func build(
        segments: [SubtitleSegment],
        fps: String = "25",
        width: Int = 1920,
        height: Int = 1080,
        font: String = "PingFang SC",
        fontSize: Int = 60,
        fontColor: String = "1 1 1 1",
        eventName: String = "SenseVoice 字幕导入",
        projectName: String = "自动字幕时间线"
    ) throws -> String {
        guard let (num, den) = frameDuration(forFps: fps) else {
            throw BuildError.unsupportedFrameRate(fps)
        }

        var body = ""
        var cursorFrames = 0
        let ordered = segments.sorted { $0.start < $1.start }

        for (index, seg) in ordered.enumerated() {
            var startFrames = quantizeFrames(seg.start, num: num, den: den)
            var endFrames = max(quantizeFrames(seg.end, num: num, den: den), startFrames + 1)
            if startFrames < cursorFrames {
                startFrames = cursorFrames
                endFrames = max(endFrames, startFrames + 1)
            }

            if startFrames > cursorFrames {
                let offset = framesToTime(cursorFrames, num: num, den: den)
                let duration = framesToTime(startFrames - cursorFrames, num: num, den: den)
                body += "                        <gap name=\"Gap\" offset=\"\(offset)\" start=\"0s\" duration=\"\(duration)\"/>\n"
            }

            let offsetStr = framesToTime(startFrames, num: num, den: den)
            let durationStr = framesToTime(endFrames - startFrames, num: num, den: den)
            let text = escapeXML(seg.text)

            body += """
                                    <title ref="r2" name="\(text)" offset="\(offsetStr)" duration="\(durationStr)" start="\(offsetStr)">
                                        <text>
                                            <text-style ref="ts\(index)">\(text)</text-style>
                                        </text>
                                        <text-style-def id="ts\(index)">
                                            <text-style font="\(escapeXML(font))" fontSize="\(fontSize)" fontFace="Regular" fontColor="\(fontColor)" alignment="center"/>
                                        </text-style-def>
                                    </title>

            """

            cursorFrames = endFrames
        }

        let nameAttribute = formatName(width: width, height: height, fps: fps)
            .map { " name=\"\($0)\"" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>

        <fcpxml version="1.9">
            <resources>
                <format id="r1"\(nameAttribute) frameDuration="\(num)/\(den)s" width="\(width)" height="\(height)" colorSpace="1-1-1 (Rec. 709)"/>
                <effect id="r2" name="Basic Title" uid="\(basicTitleUID)"/>
            </resources>
            <library>
                <event name="\(escapeXML(eventName))">
                    <project name="\(escapeXML(projectName))">
                        <sequence format="r1" tcStart="0s" tcFormat="NDF">
                            <spine>
        \(body)                    </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>

        """
    }
}
