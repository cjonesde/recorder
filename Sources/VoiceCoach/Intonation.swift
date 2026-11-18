import Foundation

enum Contour: String, Codable, Sendable {
    case rise
    case fall
    case level
    case unmeasured
}

enum IntonationConstants {
    static let jumpSemitones = 7.0
    static let terminalWindow = 0.4
    static let minimumVoiced = 6
    static let riseSemitones = 2.5
    static let fallSemitones = 1.5
    static let tail = 3
}

func cleanF0(_ f0: [Double], reference: Double? = nil) -> [Double] {
    var st = [Double](repeating: .nan, count: f0.count)
    let voiced = f0.indices.filter { f0[$0] > 0 }
    guard voiced.count >= 5 else { return st }
    let ref = reference ?? sortedMedian(voiced.map { f0[$0] })!
    for i in voiced { st[i] = 12.0 * log2(f0[i] / ref) }
    var out = st
    for i in voiced {
        let lo = max(0, i - 3)
        let hi = min(st.count, i + 4)
        let local = st[lo..<hi].filter { !$0.isNaN }
        if local.count >= 3, let middle = sortedMedian(Array(local)), abs(st[i] - middle) > IntonationConstants.jumpSemitones {
            out[i] = .nan
        }
    }
    return out
}

func terminalContour(times: [Double], st: [Double], start: Double, end: Double) -> (contour: Contour, rise: Double, fall: Double) {
    let window = IntonationConstants.terminalWindow
    let lo = max(start - 0.2, end - window - 0.3)
    var indices = times.indices.filter { times[$0] >= lo && times[$0] <= end + 0.25 && !st[$0].isNaN }
    guard indices.count >= IntonationConstants.minimumVoiced, let lastIndex = indices.last else { return (.unmeasured, 0, 0) }
    let last = times[lastIndex]
    let cutoff = max(lo, last - window)
    indices = indices.filter { times[$0] >= cutoff }
    guard indices.count >= IntonationConstants.minimumVoiced else { return (.unmeasured, 0, 0) }
    let values = indices.map { st[$0] }
    let smooth = values.indices.map { i in sortedMedian(Array(values[max(0, i - 1)..<min(values.count, i + 2)]))! }
    let tail = IntonationConstants.tail
    let endST = sortedMedian(Array(smooth.suffix(tail)))!
    let body = smooth.count > tail ? Array(smooth.dropLast(tail)) : smooth
    var iMin = 0
    var iMax = 0
    for i in body.indices {
        if body[i] < body[iMin] { iMin = i }
        if body[i] > body[iMax] { iMax = i }
    }
    let rise = endST - body[iMin]
    let fall = body[iMax] - endST
    if rise >= IntonationConstants.riseSemitones && (iMin >= iMax || fall < IntonationConstants.fallSemitones) {
        return (.rise, rise, fall)
    }
    if fall >= IntonationConstants.fallSemitones {
        return (.fall, rise, fall)
    }
    return (.level, rise, fall)
}
