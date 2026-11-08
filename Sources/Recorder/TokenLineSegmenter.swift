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
        var lastToken: Int
    }

    private(set) var confirmedThrough: Double = 0
    private(set) var boundaryStart: Double = 0
    private var consumedAtBoundary = 0

    mutating func confirm(_ tokens: [Token]) -> [Line] {
        let pending = pendingTokens(tokens)
        let words = Self.words(pending)
        guard let last = words.indices.last(where: { Self.endsLine(words, at: $0) }) else { return [] }
        var lines: [Line] = []
        var first = 0
        for index in 0...last where Self.endsLine(words, at: index) {
            lines.append(Self.line(words[first...index]))
            first = index + 1
        }
        advance(through: words[last].lastToken, of: pending)
        return lines
    }

    mutating func finish(_ tokens: [Token]) -> [Line] {
        var lines = confirm(tokens)
        let pending = pendingTokens(tokens)
        let words = Self.words(pending)
        if let last = words.last {
            lines.append(Self.line(words[...]))
            advance(through: last.lastToken, of: pending)
        }
        return lines
    }

    func tail(_ tokens: [Token]) -> String {
        Self.words(pendingTokens(tokens)).map(\.text).joined(separator: " ")
    }

    func tailLine(_ tokens: [Token]) -> Line? {
        let words = Self.words(pendingTokens(tokens))
        return words.isEmpty ? nil : Self.line(words[...])
    }

    private func pendingTokens(_ tokens: [Token]) -> [Token] {
        var seenAtBoundary = 0
        return tokens.filter { token in
            if abs(token.start - boundaryStart) < Self.tolerance {
                seenAtBoundary += 1
                return seenAtBoundary > consumedAtBoundary
            }
            return token.start >= confirmedThrough - Self.tolerance
        }
    }

    private mutating func advance(through index: Int, of pending: [Token]) {
        let token = pending[index]
        let consumedHere = pending[...index].filter { abs($0.start - token.start) < Self.tolerance }.count
        if abs(token.start - boundaryStart) < Self.tolerance {
            consumedAtBoundary += consumedHere
        } else {
            boundaryStart = token.start
            consumedAtBoundary = consumedHere
        }
        confirmedThrough = token.end
    }

    private static func words(_ tokens: [Token]) -> [Word] {
        let pieces = tokens.contains { $0.text.hasPrefix(wordMarker) }
        var words: [Word] = []
        for (index, token) in tokens.enumerated() {
            let text = token.text.replacingOccurrences(of: wordMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pieces || token.text.hasPrefix(wordMarker) || words.isEmpty {
                words.append(Word(text: text, start: token.start, end: token.end, lastToken: index))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = token.end
                words[words.count - 1].lastToken = index
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
