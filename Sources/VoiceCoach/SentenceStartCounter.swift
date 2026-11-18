import Foundation

struct SentenceStartCounter {
    static let starters: [String: Set<String>] = ["en": ["so"], "de": ["so", "also"]]
    static let windowSentences = 10
    static let minimumSentences = 5
    static let threshold = 0.1
    static let refractory = 60.0
    static let terminators: Set<Character> = [".", "!", "?", "…"]

    let starters: Set<String>
    private var recent: [Bool] = []
    private var lastTrigger = -Double.infinity
    private(set) var totalSentences = 0
    private(set) var totalStarts = 0

    init(language: String) {
        starters = Self.starters[String(language.prefix(2)).lowercased()] ?? Self.starters["en"]!
    }

    static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { terminators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(where: \.isLetter) }
    }

    static func firstWord(of sentence: String) -> String {
        let word = sentence.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return word.filter(\.isLetter).lowercased()
    }

    mutating func observe(_ line: CoachLine) -> (sentences: Int, starts: Int, matched: [String]) {
        guard line.isOwn else { return (0, 0, []) }
        var matched: [String] = []
        let sentences = Self.sentences(in: line.text)
        for sentence in sentences {
            let word = Self.firstWord(of: sentence)
            let starts = starters.contains(word)
            if starts { matched.append(word) }
            recent.append(starts)
        }
        if recent.count > Self.windowSentences { recent.removeFirst(recent.count - Self.windowSentences) }
        totalSentences += sentences.count
        totalStarts += matched.count
        return (sentences.count, matched.count, matched)
    }

    var rate: Double? {
        guard !recent.isEmpty else { return nil }
        return Double(recent.filter { $0 }.count) / Double(recent.count)
    }

    mutating func shouldTrigger(at t: Double) -> Bool {
        guard recent.count >= Self.minimumSentences, let rate, rate >= Self.threshold, t - lastTrigger >= Self.refractory else { return false }
        lastTrigger = t
        return true
    }

    func sample() -> [String: Double] {
        var values: [String: Double] = ["sentences": Double(totalSentences), "starts": Double(totalStarts)]
        if let rate { values["rate"] = rate }
        return values
    }
}
