import Foundation
import Testing

@testable import FCPSubtitleCore

/// Tokens as SenseVoice emits them: one per Chinese character or punctuation
/// mark, English as word pieces ("fin", "al", " cut"), numbers digit by digit.
private func window(_ pieces: [String], step: Double = 0.2, start: Double = 0) -> TranscriptWindow {
    let tokens = pieces.enumerated().map { TimedToken(text: $1, time: start + Double($0) * step) }
    return TranscriptWindow(start: start, end: start + Double(pieces.count) * step, tokens: tokens)
}

private func chars(_ s: String) -> [String] { s.map(String.init) }

private func layout(
    _ windows: [TranscriptWindow], maxChars: Int = 18, punctuation: PunctuationStyle = .keep,
    hotwords: [String] = []
) -> [String] {
    SubtitleLayout.segments(
        from: RawTranscript(windows: windows),
        options: LayoutOptions(maxChars: maxChars, punctuation: punctuation, hotwords: hotwords)
    ).map(\.text)
}

// MARK: - Line breaking

@Test func everySentenceStartsANewLine() {
    let lines = layout([window(chars("大家好，欢迎来到我的频道。今天聊聊字幕。"))])
    #expect(lines == ["大家好，欢迎来到我的频道。", "今天聊聊字幕。"])
}

@Test func longSentencesBreakAfterACommaWithinTheLimit() {
    let lines = layout([window(chars("其实现在的语音识别模型已经非常准确了，只要几秒钟就能生成完整的字幕文件。"))])
    #expect(lines == ["其实现在的语音识别模型已经非常准确了，", "只要几秒钟就能生成完整的字幕文件。"])
}

@Test func linesNeverExceedTheLimit() {
    let text = "很多剪辑师都觉得手动打字幕非常浪费时间尤其是一个小时的采访素材光是听写就要花掉一整个下午"
    for limit in [8, 12, 16] {
        for line in layout([window(chars(text))], maxChars: limit) {
            #expect(SubtitleLayout.width(line) <= Double(limit), "\(line) > \(limit)")
        }
    }
}

@Test func englishWordsAndNumbersStayWhole() {
    let pieces = chars("价格是") + ["3", ".", "5"] + chars("元，用的是") + ["i", "phone", "1", "5", " pro"]
        + chars("和") + ["m", "ac", "book", " air", "。"]
    let lines = layout([window(pieces)], maxChars: 10)
    #expect(lines.joined() == "价格是3.5元，用的是iphone15 pro和macbook air。")
    for line in lines {
        #expect(!line.hasPrefix("ac") && !line.hasPrefix("phone") && !line.hasPrefix("5元"))
    }
    #expect(lines.contains { $0.contains("macbook air") })
}

@Test func aDecimalPointIsNotASentenceEnd() {
    let lines = layout([window(chars("涨了") + ["3", ".", "5"] + chars("倍。"))])
    #expect(lines == ["涨了3.5倍。"])
}

@Test func linesAreTimedByTheirOwnTokens() {
    let w = window(chars("大家好。今天聊聊字幕。"), step: 0.3, start: 10)
    let segments = SubtitleLayout.segments(
        from: RawTranscript(windows: [w]), options: LayoutOptions(maxChars: 18, punctuation: .keep))
    #expect(segments.count == 2)
    #expect(abs(segments[0].start - 10) < 0.001)
    #expect(abs(segments[1].start - (10 + 4 * 0.3)) < 0.001)  // "今" is the 5th token
    #expect(segments[0].end <= segments[1].start)
}

@Test func tinyFragmentsJoinThePreviousLine() {
    let lines = layout([window(chars("我觉得可以。嗯。"))])
    #expect(lines == ["我觉得可以。嗯。"])
}

// MARK: - Punctuation styles

@Test(arguments: [
    (PunctuationStyle.keep, "大家好，欢迎来到我的频道。"),
    (.trimEnd, "大家好，欢迎来到我的频道"),
    (.subtitle, "大家好 欢迎来到我的频道"),
])
func punctuationStyles(style: PunctuationStyle, expected: String) {
    #expect(SubtitleLayout.applyPunctuation("大家好，欢迎来到我的频道。", style: style) == expected)
}

@Test func subtitleStyleKeepsQuestionMarksAndDecimals() {
    #expect(SubtitleLayout.applyPunctuation("涨了3.5倍，你知道吧？", style: .subtitle) == "涨了3.5倍 你知道吧？")
    #expect(SubtitleLayout.applyPunctuation("真的吗！", style: .trimEnd) == "真的吗！")
}

// MARK: - Hotwords

@Test func hotwordsFixSameSoundingCharacters() {
    let corrector = HotwordCorrector(terms: ["剪映", "节点式", "达芬奇"])
    #expect(corrector.correct("简映的智能字幕") == "剪映的智能字幕")
    #expect(corrector.correct("达芬奇的节点是调色") == "达芬奇的节点式调色")
    #expect(corrector.correct("剪映很好用") == "剪映很好用")
    #expect(corrector.correct("今天天气不错") == "今天天气不错")
}

@Test func latinHotwordsNormalizeCasingAndSpacing() {
    let corrector = HotwordCorrector(terms: ["Final Cut Pro", "iPhone"])
    #expect(corrector.correct("用final cut pro剪") == "用Final Cut Pro剪")
    #expect(corrector.correct("用finalcut pro剪") == "用Final Cut Pro剪")
    #expect(corrector.correct("买了iphone") == "买了iPhone")
    #expect(corrector.correct("iphones") == "iphones")  // not inside a longer word
}

@Test func hotwordsApplyDuringLayout() {
    let lines = layout([window(chars("简映的智能字幕虽然方便。"))], hotwords: ["剪映"])
    #expect(lines == ["剪映的智能字幕虽然方便。"])
}

// MARK: - Timing rules

private func seg(_ start: Double, _ end: Double) -> SubtitleSegment {
    SubtitleSegment(start: start, duration: end - start, text: "x")
}

@Test func shortGapsCloseToTwoFrames() {
    let out = TimingRules(frameDuration: 0.04).apply([seg(0, 1.5), seg(1.8, 3)])
    #expect(abs(out[0].end - (1.8 - 0.08)) < 1e-9)
}

@Test func longGapsKeepTheirSpaceAndLingerALittle() {
    let out = TimingRules(frameDuration: 0.04).apply([seg(0, 1.5), seg(4, 5)])
    #expect(abs(out[0].end - 2.0) < 1e-9)  // +0.5 s tail
    #expect(out[1].start - out[0].end >= 0.5)
}

@Test func briefLinesGetTheMinimumDuration() {
    let out = TimingRules(frameDuration: 0.04).apply([seg(0, 0.2), seg(5, 5.3)])
    #expect(out[0].duration >= 0.8 - 1e-9)
    #expect(out[1].duration >= 0.8 - 1e-9)
}

@Test func linesNeverOverlap() {
    let out = TimingRules(frameDuration: 0.04).apply([seg(0, 2), seg(1, 3), seg(2.5, 4)])
    for i in 0..<(out.count - 1) {
        #expect(out[i].end <= out[i + 1].start)
    }
}

// MARK: - Windows

@Test func nearbySpeechIsMergedIntoOneWindow() {
    let sr = 16000
    let ranges = [0..<sr, (sr + sr / 4)..<(2 * sr), (4 * sr)..<(5 * sr)]  // 0.25 s gap, then 2 s gap
    let merged = Transcriber.mergedRanges(ranges, maxGap: Int(0.6 * Double(sr)), maxLength: 20 * sr)
    #expect(merged == [0..<(2 * sr), (4 * sr)..<(5 * sr)])
}

@Test func windowsStopGrowingAtTheMaximumLength() {
    let sr = 16000
    let ranges = (0..<10).map { i in (i * 3 * sr)..<((i * 3 + 2) * sr) }  // 2 s speech, 1 s... gaps
    let tight = ranges.map { $0.lowerBound..<($0.upperBound + sr / 2 + sr / 3) }  // gaps under 0.6 s
    let merged = Transcriber.mergedRanges(tight, maxGap: Int(0.6 * Double(sr)), maxLength: 10 * sr)
    #expect(merged.allSatisfy { $0.count <= 10 * sr })
    #expect(merged.count > 1)
}

@Test func tokensWithoutTimestampsAreSpreadOverTheWindow() {
    let recognition = Recognition(text: "你好", tokens: ["你", "好"], timestamps: [])
    let tokens = Transcriber.timedTokens(recognition, offset: 0, start: 2, end: 3)
    #expect(tokens.map(\.time) == [2, 2.5])
}
