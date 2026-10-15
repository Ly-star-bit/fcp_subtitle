import Foundation
import Testing

@testable import FCPSubtitleCore

private let sample = [
    SubtitleSegment(start: 0.5, duration: 1.2, text: "大家好"),
    SubtitleSegment(start: 2.0, duration: 1.5, text: "今天聊聊字幕"),
]

// MARK: - FCPXML

@Test(arguments: [
    ("23.976", "FFVideoFormat1080p2398"),
    ("24", "FFVideoFormat1080p24"),
    ("25", "FFVideoFormat1080p25"),
    ("29.97", "FFVideoFormat1080p2997"),
    ("30", "FFVideoFormat1080p30"),
    ("50", "FFVideoFormat1080p50"),
    ("59.94", "FFVideoFormat1080p5994"),
    ("60", "FFVideoFormat1080p60"),
])
func standardHDFormatNames(fps: String, name: String) throws {
    let xml = try FCPXMLBuilder.build(segments: sample, fps: fps)
    #expect(xml.contains("<format id=\"r1\" name=\"\(name)\""))
}

@Test func nonStandardSizeOmitsFormatName() throws {
    let xml = try FCPXMLBuilder.build(segments: sample, fps: "29.97", width: 1080, height: 1920)
    #expect(xml.contains("<format id=\"r1\" frameDuration=\"1001/30000s\" width=\"1080\" height=\"1920\""))
}

@Test func unsupportedFrameRateThrows() {
    #expect(throws: FCPXMLBuilder.BuildError.self) {
        try FCPXMLBuilder.build(segments: sample, fps: "12")
    }
}

@Test func fiftyNineNinetyFourUsesNTSCFrameDuration() throws {
    let xml = try FCPXMLBuilder.build(segments: sample, fps: "59.94")
    #expect(xml.contains("frameDuration=\"1001/60000s\""))
    // 0.5 s at 59.94 fps is 30 frames = 30030/60000 s.
    #expect(xml.contains("offset=\"1001/2000s\""))
}

@Test(arguments: [
    (23.976024, "23.976"), (24.0, "24"), (25.0, "25"), (29.970029, "29.97"), (30.0, "30"),
    (29.986, "30"), (50.0, "50"), (59.940059, "59.94"), (60.0, "60"),
])
func measuredFrameRatesMapToLabels(rate: Double, label: String) {
    #expect(FCPXMLBuilder.fpsLabel(matching: rate) == label)
}

@Test(arguments: [15.0, 120.0, 0.0, 12.5])
func unusualFrameRatesHaveNoLabel(rate: Double) {
    #expect(FCPXMLBuilder.fpsLabel(matching: rate) == nil)
}

@Test func assScriptResolutionFollowsTimelineSize() throws {
    let ass = try SubtitleExporter.export(
        segments: sample, format: .ass, width: 1080, height: 1920)
    #expect(ass.contains("PlayResX: 1080\nPlayResY: 1920"))
}

// MARK: - SRT encodings

private let srtText = "1\r\n00:00:01,000 --> 00:00:02,500\r\n大家好，欢迎来到我的频道。\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,200\r\n今天聊聊字幕。\r\n"

private func expectParsed(_ segments: [SubtitleSegment]) {
    #expect(segments.map(\.text) == ["大家好，欢迎来到我的频道。", "今天聊聊字幕。"])
    #expect(segments.first?.start == 1.0)
}

@Test func readsGB18030Subtitles() throws {
    let data = try #require(srtText.data(using: SRTParser.gb18030))
    #expect(String(data: data, encoding: .utf8) == nil)  // really not UTF-8
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fcpsub-test-\(UUID().uuidString).srt")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    expectParsed(try SRTParser.parse(contentsOf: url))
}

@Test func readsUTF16WithBOM() throws {
    var data = Data([0xFF, 0xFE])
    data.append(try #require(srtText.data(using: .utf16LittleEndian)))
    expectParsed(SRTParser.parse(try #require(SRTParser.decodeText(data))))
}

@Test func readsUTF8WithBOM() throws {
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(try #require(srtText.data(using: .utf8)))
    expectParsed(SRTParser.parse(try #require(SRTParser.decodeText(data))))
}

// MARK: - Transcriber helpers

@Test func paddingIsCappedAtHalfTheGap() {
    // Speech at 1000..<2000 and 2100..<3000 in a 4000-sample file, pad 250.
    let padded = Transcriber.paddedRanges([1000..<2000, 2100..<3000], total: 4000, padding: 250)
    #expect(padded == [750..<2050, 2050..<3250])
}

@Test func paddingStopsAtFileEdges() {
    let padded = Transcriber.paddedRanges([100..<900], total: 1000, padding: 250)
    #expect(padded == [0..<1000])
}

@Test func touchingRangesGetNoPaddingBetweenThem() {
    let padded = Transcriber.paddedRanges([0..<500, 500..<1000], total: 1000, padding: 250)
    #expect(padded == [0..<500, 500..<1000])
}

private final class Recorder: @unchecked Sendable {
    var values: [Double] = []
}

@Test func progressIsThrottled() {
    let recorder = Recorder()
    var throttle = ProgressThrottle { recorder.values.append($0) }
    let windows = 18_677  // VAD windows in 10 minutes of audio
    for i in 1...windows { throttle.report(Double(i) / Double(windows)) }
    #expect(recorder.values.count <= 201)
    #expect(recorder.values.last == 1)
    #expect(recorder.values == recorder.values.sorted())
}
