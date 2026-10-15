import Foundation
import NaturalLanguage

/// How punctuation from recognition appears in subtitle lines.
public enum PunctuationStyle: String, CaseIterable, Codable, Sendable {
    /// As recognized.
    case keep
    /// Drop a line's trailing 。，、；： (question/exclamation marks stay).
    case trimEnd
    /// Chinese subtitle convention: commas, periods and the like become a
    /// space; question and exclamation marks stay.
    case subtitle

    public var displayName: String {
        switch self {
        case .keep: return "保留标点"
        case .trimEnd: return "去掉句末标点"
        case .subtitle: return "字幕规范（逗号句号换成空格）"
        }
    }
}

public struct LayoutOptions: Equatable, Sendable {
    /// Line width limit, counted in Chinese characters (Latin letters and
    /// digits count as half). 0 splits only at sentence ends.
    public var maxChars: Int
    public var punctuation: PunctuationStyle
    /// nil leaves line timing exactly as recognized.
    public var timing: TimingRules?
    /// Proper nouns whose same-sounding misrecognitions get corrected.
    public var hotwords: [String]

    public init(
        maxChars: Int = 18, punctuation: PunctuationStyle = .trimEnd,
        timing: TimingRules? = nil, hotwords: [String] = []
    ) {
        self.maxChars = maxChars
        self.punctuation = punctuation
        self.timing = timing
        self.hotwords = hotwords
    }
}

/// Turns recognized tokens into subtitle lines.
///
/// Every sentence starts a new line. A sentence wider than `maxChars` is
/// broken where a reader would pause — after a comma, at a pause in speech,
/// or between words (system word segmentation for Chinese) — never inside an
/// English word or a number, and the pieces are kept about equally long. Each
/// line is timed by its own first and last tokens.
public enum SubtitleLayout {
    public static func segments(
        from transcript: RawTranscript, options: LayoutOptions
    ) -> [SubtitleSegment] {
        let corrector = HotwordCorrector(terms: options.hotwords)
        var segments: [SubtitleSegment] = []
        for window in transcript.windows {
            for line in lines(in: window, maxChars: options.maxChars) {
                let text = applyPunctuation(corrector.correct(line.text), style: options.punctuation)
                guard !text.isEmpty else { continue }
                segments.append(
                    SubtitleSegment(start: line.start, duration: line.end - line.start, text: text))
            }
        }
        return options.timing?.apply(segments) ?? segments
    }

    // MARK: - Units

    /// Where a line may break after a unit, from worst to best.
    enum Break: Int, Comparable {
        case none, word, pause, clause, sentence
        static func < (a: Break, b: Break) -> Bool { a.rawValue < b.rawValue }
    }

    /// The smallest thing a line can be broken around: one Chinese character
    /// or one whole Latin word / number, plus any punctuation that follows it.
    struct Unit {
        var core: String
        var trailing = ""
        var time: Double
        var lastTime: Double
        var spaceBefore: Bool
        var breakAfter = Break.none
        /// Ends a connective (但是, 所以…) that belongs at the start of a line.
        var endsConnective = false

        var text: String { core + trailing }
        var width: Double { SubtitleLayout.width(core + trailing) }
        var isWord: Bool { core.unicodeScalars.allSatisfy { !SubtitleLayout.isWide($0) } }
    }

    static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    static let clauseMarks: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]

    static func units(from tokens: [TimedToken]) -> [Unit] {
        var units: [Unit] = []
        for (index, token) in tokens.enumerated() {
            let leadingSpace = token.text.hasPrefix(" ") || token.text.hasPrefix("▁")
            let piece = token.text.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }

            if isPunctuation(piece) {
                guard !units.isEmpty else { continue }  // nothing to attach a leading mark to
                let last = units.count - 1
                // A point or comma between digits belongs to the number (3.5, 1,000).
                let next = tokens.dropFirst(index + 1).first?.text.trimmingCharacters(in: .whitespaces)
                if piece == "." || piece == ",", units[last].core.last?.isNumber == true,
                    next?.first?.isNumber == true
                {
                    units[last].core += piece
                    continue
                }
                units[last].trailing += piece
                units[last].lastTime = token.time
                if piece.contains(where: { sentenceEnds.contains($0) || $0 == "." }) {
                    units[last].breakAfter = .sentence
                } else if piece.contains(where: { clauseMarks.contains($0) }) {
                    units[last].breakAfter = max(units[last].breakAfter, .clause)
                }
                continue
            }

            let isWordPiece = piece.unicodeScalars.allSatisfy { !isWide($0) }
            if isWordPiece, !leadingSpace, let last = units.last, last.isWord, last.trailing.isEmpty {
                // Continuation of a word or number: "fin"+"al", "1"+"2"+"%".
                units[units.count - 1].core += piece
                units[units.count - 1].lastTime = token.time
            } else {
                units.append(
                    Unit(core: piece, time: token.time, lastTime: token.time, spaceBefore: leadingSpace))
            }
        }
        markWordAndPauseBreaks(&units)
        return units
    }

    /// A gap this long between tokens reads as a pause in speech.
    static let pauseGap = 0.5

    static func markWordAndPauseBreaks(_ units: inout [Unit]) {
        guard units.count > 1 else { return }
        // Word boundaries inside Chinese come from the system word segmenter.
        var plain = ""
        var ends: [Int] = []
        for unit in units {
            plain += unit.core
            ends.append(plain.utf16.count)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = plain
        if plain.unicodeScalars.contains(where: isWide) { tokenizer.setLanguage(.simplifiedChinese) }
        var wordEnds = Set<Int>()
        var connectiveEnds = Set<Int>()
        tokenizer.enumerateTokens(in: plain.startIndex..<plain.endIndex) { range, _ in
            let end = plain.utf16.distance(from: plain.startIndex, to: range.upperBound)
            wordEnds.insert(end)
            if connectives.contains(String(plain[range])) { connectiveEnds.insert(end) }
            return true
        }
        for i in units.indices where connectiveEnds.contains(ends[i]) {
            units[i].endsConnective = true
        }
        for i in 0..<(units.count - 1) {
            if units[i + 1].time - units[i].lastTime >= pauseGap {
                units[i].breakAfter = max(units[i].breakAfter, .pause)
            } else if units[i].isWord && units[i + 1].isWord {
                // Keep runs of Latin words together: "Final Cut Pro", "macbook air".
                continue
            } else if bindsToNext(units[i], units[i + 1]) {
                // The segmenter splits numbers from their measure words (几|秒|钟, 一|整个).
                continue
            } else if units[i].isWord || units[i + 1].isWord || wordEnds.contains(ends[i]) {
                units[i].breakAfter = max(units[i].breakAfter, .word)
            }
        }
    }

    static let connectives: Set<String> = [
        "但是", "可是", "不过", "而且", "并且", "然后", "所以", "因为", "因此", "如果", "虽然", "或者", "还是",
        "于是", "那么", "以及", "还有", "就是",
    ]

    static let numerals: Set<String> = [
        "一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "亿", "几", "半", "第",
    ]

    /// Pairs that must stay on one line though the word segmenter separates
    /// them: a number and the measure word or noun after it (三个, 12个, 3.5元),
    /// and 秒钟 / 分钟 / 点钟.
    static func bindsToNext(_ unit: Unit, _ next: Unit) -> Bool {
        guard unit.trailing.isEmpty, !next.isWord else { return false }
        if numerals.contains(unit.core) { return true }
        if unit.isWord, unit.core.last?.isNumber == true { return true }
        return next.core == "钟" && ["秒", "分", "点"].contains(unit.core)
    }

    // MARK: - Lines

    struct Line {
        var text: String
        var start: Double
        var end: Double
    }

    /// Time after a line's last token starts that it stays up for, before the
    /// timing rules smooth it (roughly one spoken character).
    static let lastTokenHold = 0.4

    static func lines(in window: TranscriptWindow, maxChars: Int) -> [Line] {
        let units = units(from: window.tokens)
        guard !units.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        var sentenceStart = 0
        for i in units.indices where units[i].breakAfter == .sentence || i == units.count - 1 {
            ranges += split(sentenceStart..<(i + 1), units: units, maxChars: maxChars)
            sentenceStart = i + 1
        }
        ranges = mergingFragments(ranges, units: units, maxChars: maxChars)

        return ranges.enumerated().map { index, range in
            let first = units[range.lowerBound]
            let last = units[range.upperBound - 1]
            let nextStart = index + 1 < ranges.count ? units[ranges[index + 1].lowerBound].time : window.end
            let start = max(first.time, 0)
            let end = max(min(nextStart, last.lastTime + lastTokenHold), start + 0.1)
            var text = ""
            for i in range {
                if i > range.lowerBound, units[i].spaceBefore { text += " " }
                text += units[i].text
            }
            return Line(text: text, start: start, end: end)
        }
    }

    static let attachesLeft: Set<String> = [
        "了", "的", "地", "得", "着", "过", "吗", "呢", "吧", "啊", "呀", "嘛", "们", "么", "里", "上",
    ]
    static let attachesRight: Set<String> = [
        "在", "和", "跟", "把", "被", "对", "从", "向", "给", "与", "的",
        // adverbs that modify what follows
        "先", "再", "就", "也", "都", "还", "又", "才", "很", "最", "更", "太", "不", "没",
    ]

    /// Breaks one sentence into lines no wider than `maxChars`. All possible
    /// breakings are weighed together (dynamic programming, as in paragraph
    /// typesetting), so one awkward early break can't force worse ones later.
    static func split(_ sentence: Range<Int>, units: [Unit], maxChars: Int) -> [Range<Int>] {
        let limit = Double(maxChars)
        guard maxChars > 0, fitWidth(sentence, units) > limit else { return [sentence] }

        let start = sentence.lowerBound
        let end = sentence.upperBound
        // best[j - start]: cheapest layout of start..<j; from[j - start]: where its last line begins.
        var best = [Double](repeating: .infinity, count: end - start + 1)
        var from = [Int](repeating: start, count: end - start + 1)
        best[0] = 0
        for j in (start + 1)...end {
            for i in stride(from: j - 1, through: start, by: -1) {
                let w = fitWidth(i..<j, units)
                if w > limit && j - i > 1 { break }  // starting earlier only gets wider
                let cost = best[i - start]
                    + lineCost(i..<j, width: w, isLast: j == end, units: units, limit: limit)
                if cost < best[j - start] {
                    best[j - start] = cost
                    from[j - start] = i
                }
            }
        }
        var lines: [Range<Int>] = []
        var j = end
        while j > start {
            let i = from[j - start]
            lines.insert(i..<j, at: 0)
            j = i
        }
        return lines
    }

    /// Cost of one line in `split`: where it breaks matters most (after a
    /// comma is free, inside a word is expensive), then how much room it wastes.
    static func lineCost(
        _ line: Range<Int>, width: Double, isLast: Bool, units: [Unit], limit: Double
    ) -> Double {
        var cost = 1.0  // every line costs a little, so lines aren't split needlessly
        if width < 3 { cost += 8 }  // a word or two on its own line flashes by
        if width > limit { cost += 50 }  // a single word wider than the line
        guard !isLast else {
            // A sentence's last line much shorter than the rest looks lopsided.
            return cost + max(0.5 - width / limit, 0) * 4
        }

        let last = line.upperBound - 1
        let kind = units[last].breakAfter
        var penalty: Double
        switch kind {
        case .sentence, .clause: penalty = 0
        case .pause: penalty = 1
        case .word: penalty = 4
        case .none: penalty = 12
        }
        // Particles read badly at the start of a line, prepositions at the end.
        if kind < .clause,
            attachesLeft.contains(units[last + 1].core) || attachesRight.contains(units[last].core)
                || units[last].endsConnective
        {
            penalty += 3
        }
        let slack = (limit - width) / limit
        return cost + penalty + slack * slack * 6
    }

    /// Folds a one- or two-character line ("嗯", "对。") into the line before
    /// it when they fit together, so it doesn't flash on screen by itself.
    static func mergingFragments(_ ranges: [Range<Int>], units: [Unit], maxChars: Int) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, width(range, units) < 3,
                maxChars <= 0 || width(last.lowerBound..<range.upperBound, units) <= Double(maxChars),
                units[range.lowerBound].time - units[last.upperBound - 1].lastTime < pauseGap
            {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - Punctuation

    static let softMarks: Set<Character> = ["，", "。", "、", "；", "：", ",", ".", ";", ":"]

    public static func applyPunctuation(_ text: String, style: PunctuationStyle) -> String {
        switch style {
        case .keep:
            return text.trimmingCharacters(in: .whitespaces)
        case .trimEnd:
            var result = text.trimmingCharacters(in: .whitespaces)
            while let last = result.last, softMarks.contains(last) { result.removeLast() }
            return result.trimmingCharacters(in: .whitespaces)
        case .subtitle:
            let chars = Array(text)
            var out = ""
            for (i, c) in chars.enumerated() {
                let inNumber =
                    (c == "." || c == ",") && i > 0 && i + 1 < chars.count
                    && chars[i - 1].isNumber && chars[i + 1].isNumber
                out.append(softMarks.contains(c) && !inNumber ? " " : c)
            }
            return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
    }

    // MARK: - Width

    /// Display width in Chinese characters: CJK and full-width forms count 1,
    /// everything else (Latin, digits, spaces) counts half.
    public static func width(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 1 : 0.5) }
    }

    static func width(_ range: Range<Int>, _ units: [Unit]) -> Double {
        units[range].reduce(0) { $0 + $1.width } + Double(units[range].dropFirst().filter(\.spaceBefore).count) * 0.5
    }

    /// Width that has to fit the limit: a line's trailing comma or period is
    /// dropped by the punctuation styles (or may hang over), so it doesn't
    /// count — otherwise "准确了，" would push "了" onto the next line.
    static func fitWidth(_ range: Range<Int>, _ units: [Unit]) -> Double {
        guard let last = range.last else { return 0 }
        return width(range, units) - width(String(units[last].trailing.filter { softMarks.contains($0) }))
    }

    static func isWide(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3040...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    static func isPunctuation(_ piece: String) -> Bool {
        piece.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) && $0 != "%" && $0 != "'"
        }
    }
}
