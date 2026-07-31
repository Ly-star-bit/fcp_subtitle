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
    public static let basicTitleUID =
        ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

    /// fps label -> frame duration (numerator, denominator)
    public static let frameDurations: [(label: String, num: Int, den: Int)] = [
        ("23.976", 1001, 24000),
        ("24", 1, 24),
        ("25", 1, 25),
        ("29.97", 1001, 30000),
        ("30", 1, 30),
    ]

    public static var fpsLabels: [String] { frameDurations.map(\.label) }

    static func frameDuration(forFps fps: String) -> (num: Int, den: Int)? {
        frameDurations.first { $0.label == fps }.map { ($0.num, $0.den) }
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
    ) -> String {
        guard let (num, den) = frameDuration(forFps: fps) else {
            preconditionFailure("unsupported fps \(fps)")
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

        let formatName = "FFVideoFormat\(height)p\(fps.replacingOccurrences(of: ".", with: ""))"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>

        <fcpxml version="1.9">
            <resources>
                <format id="r1" name="\(formatName)" frameDuration="\(num)/\(den)s" width="\(width)" height="\(height)" colorSpace="1-1-1 (Rec. 709)"/>
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
