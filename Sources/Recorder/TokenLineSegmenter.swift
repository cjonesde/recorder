import Foundation

struct TokenLineSegmenter {
    struct Token: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    typealias Line = (text: String, start: Double, end: Double)

    static let pauseSeconds = 0.8
    private static let wordMarker = "▁"
    private static let sentenceEnds: Set<Character> = [".", "?", "!"]
    private static let tolerance = 1e-6

    private struct Word {
        var text: String
        let start: Double
        var end: Double
    }

    private(set) var confirmedThrough: Double = 0

    mutating func confirm(_ tokens: [Token]) -> [Line] {
        let words = pendingWords(tokens)
        guard let last = words.indices.last(where: { Self.endsLine(words, at: $0) }) else { return [] }
        var lines: [Line] = []
        var first = 0
        for index in 0...last where Self.endsLine(words, at: index) {
            lines.append(Self.line(words[first...index]))
            first = index + 1
        }
        confirmedThrough = words[last].end
        return lines
    }

    mutating func finish(_ tokens: [Token]) -> [Line] {
        var lines = confirm(tokens)
        let words = pendingWords(tokens)
        if let last = words.last {
            lines.append(Self.line(words[...]))
            confirmedThrough = last.end
        }
        return lines
    }

    func tail(_ tokens: [Token]) -> String {
        pendingWords(tokens).map(\.text).joined(separator: " ")
    }

    func tailLine(_ tokens: [Token]) -> Line? {
        let words = pendingWords(tokens)
        return words.isEmpty ? nil : Self.line(words[...])
    }

    private func pendingWords(_ tokens: [Token]) -> [Word] {
        Self.words(tokens.filter { $0.start >= confirmedThrough - Self.tolerance })
    }

    private static func words(_ tokens: [Token]) -> [Word] {
        let pieces = tokens.contains { $0.text.hasPrefix(wordMarker) }
        var words: [Word] = []
        for token in tokens {
            let text = token.text.replacingOccurrences(of: wordMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pieces || token.text.hasPrefix(wordMarker) || words.isEmpty {
                words.append(Word(text: text, start: token.start, end: token.end))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = token.end
            }
        }
        return words.filter { !$0.text.isEmpty }
    }

    private static func endsLine(_ words: [Word], at index: Int) -> Bool {
        if let last = words[index].text.last, sentenceEnds.contains(last) { return true }
        guard index + 1 < words.count else { return false }
        return words[index + 1].start - words[index].end >= pauseSeconds - tolerance
    }

    private static func line(_ words: ArraySlice<Word>) -> Line {
        (words.map(\.text).joined(separator: " "), words.first!.start, words.last!.end)
    }
}
