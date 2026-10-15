import Foundation

/// Fixes misrecognized proper nouns from a list of correct spellings.
///
/// Chinese terms are matched by sound: a run of characters with the same
/// toneless pinyin as a term is replaced by the term (简映 → 剪映, 节点是 →
/// 节点式), so users list only the right spelling, not every wrong one.
/// Latin terms get their casing and spacing normalized ("final cut pro" →
/// "Final Cut Pro"). Common words make poor terms: "字幕" would also turn a
/// legitimate "字母" into "字幕".
public struct HotwordCorrector {
    private let chinese: [(term: [Character], sounds: [String])]
    private let latin: [(pattern: NSRegularExpression, term: String)]

    public init(terms: [String]) {
        var chinese: [(term: [Character], sounds: [String])] = []
        var latin: [(pattern: NSRegularExpression, term: String)] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let chars = Array(term)
            let sounds = chars.compactMap(Self.sound)
            if chars.count >= 2, sounds.count == chars.count {
                chinese.append((chars, sounds))
            } else if !term.unicodeScalars.contains(where: SubtitleLayout.isWide) {
                // Words may be glued together or spaced differently: "finalcut pro".
                let words = term.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                let body = words.joined(separator: "\\s*")
                if let regex = try? NSRegularExpression(
                    pattern: "(?<![A-Za-z0-9])\(body)(?![A-Za-z0-9])", options: .caseInsensitive)
                {
                    latin.append((regex, term))
                }
            }
        }
        self.chinese = chinese.sorted { $0.term.count > $1.term.count }
        self.latin = latin
    }

    public var isEmpty: Bool { chinese.isEmpty && latin.isEmpty }

    public func correct(_ text: String) -> String {
        guard !isEmpty else { return text }
        var chars = Array(text)
        if !chinese.isEmpty {
            let sounds = chars.map(Self.sound)
            var i = 0
            scan: while i < chars.count {
                for (term, termSounds) in chinese where i + term.count <= chars.count {
                    let window = i..<(i + term.count)
                    guard zip(sounds[window], termSounds).allSatisfy({ $0 == $1 }) else { continue }
                    chars.replaceSubrange(window, with: term)
                    i += term.count
                    continue scan
                }
                i += 1
            }
        }
        var result = String(chars)
        for (pattern, term) in latin {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return result
    }

    /// Toneless pinyin of a Chinese character, nil for anything else.
    static func sound(_ c: Character) -> String? {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first,
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x2FA1F).contains(scalar.value)
        else { return nil }
        let s = NSMutableString(string: String(c))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        return (s as String).trimmingCharacters(in: .whitespaces).lowercased()
    }
}
