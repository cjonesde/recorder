import AVFoundation
import Foundation
import VoiceCoach

struct ReplayError: Error, CustomStringConvertible {
    let description: String
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class ChannelReader {
    let rate: Double
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let channel: Int?
    private var padFrames: Int
    private var framesDelivered = 0
    private(set) var finished = false

    init(url: URL, channel: Int?, offsetSeconds: Double) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        rate = format.sampleRate
        if let channel, channel >= Int(format.channelCount) {
            throw ReplayError(description: "\(url.lastPathComponent) has \(format.channelCount) channel(s), channel \(channel) requested")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw ReplayError(description: "cannot allocate a buffer for \(url.lastPathComponent)")
        }
        self.buffer = buffer
        self.channel = channel
        if offsetSeconds >= 0 {
            padFrames = Int(offsetSeconds * rate)
        } else {
            padFrames = 0
            file.framePosition = min(file.length, AVAudioFramePosition(-offsetSeconds * rate))
        }
    }

    func read(through seconds: Double, into out: inout [Float]) throws {
        out.removeAll(keepingCapacity: true)
        var wanted = Int(seconds * rate) - framesDelivered
        guard wanted > 0, !finished else { return }
        if padFrames > 0 {
            let pad = min(padFrames, wanted)
            out.append(contentsOf: repeatElement(0, count: pad))
            padFrames -= pad
            wanted -= pad
            framesDelivered += pad
        }
        while wanted > 0 {
            guard file.framePosition < file.length else {
                finished = true
                return
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(wanted, Int(buffer.frameCapacity))))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else {
                finished = true
                return
            }
            if let channel {
                out.append(contentsOf: UnsafeBufferPointer(start: data[channel], count: got))
            } else {
                let channels = Int(buffer.format.channelCount)
                let scale = 1 / Float(channels)
                for frame in 0..<got {
                    var sum: Float = 0
                    for index in 0..<channels { sum += data[index][frame] }
                    out.append(sum * scale)
                }
            }
            wanted -= got
            framesDelivered += got
        }
    }
}

struct ReplayLine: Decodable {
    let start: Double
    let end: Double
    let text: String
    let isOwn: Bool
}

struct Options {
    var mic: URL?
    var desktop: URL?
    var recording: URL?
    var desktopOffset = 0.0
    var lines: URL?
    var lineLag = 3.0
    var language = "de"
    var attendees: Int?
    var events: URL?
    var hud: URL?
    var seed: UInt64 = 1
    var withholding = true
    var baselineRate: Double?
    var baselineLevelDB: Double?
    var transcriptCues = true
    var step = 0.05

    static let usage = """
    usage: coach-replay (--recording audio.m4a | --mic mic.m4a --desktop call.m4a) [options]
      --recording PATH       Recorder audio.m4a (call audio left, mic right)
      --mic PATH             mic file (all channels mixed to mono)
      --desktop PATH         call audio file (all channels mixed to mono)
      --desktop-offset S     call audio starts S seconds after the mic (negative skips its start)
      --lines PATH           JSON array of {start, end, text, isOwn}
      --line-lag S           seconds after a line's end before it reaches the coach (default 3)
      --language CODE        de or en (default de)
      --attendees N          picks the preset like the calendar does
      --events PATH          write the coach.jsonl events here
      --hud PATH             write HUD changes here as TSV
      --seed N               seed for the cue coin flip (default 1)
      --no-withholding       show every cue
      --baseline-rate R      syllables per second from earlier sessions
      --baseline-level DB    level from earlier sessions
      --engine-lags          treat transcript cues as lagging (Parakeet, Nemotron)
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw ReplayError(description: "\(flag) needs a value") }
            return next
        }
        func number(_ flag: String) throws -> Double {
            let raw = try value(flag)
            guard let parsed = Double(raw) else { throw ReplayError(description: "\(flag) expects a number, got \(raw)") }
            return parsed
        }
        while let flag = iterator.next() {
            switch flag {
            case "--mic": options.mic = URL(fileURLWithPath: try value(flag))
            case "--desktop": options.desktop = URL(fileURLWithPath: try value(flag))
            case "--recording": options.recording = URL(fileURLWithPath: try value(flag))
            case "--desktop-offset": options.desktopOffset = try number(flag)
            case "--lines": options.lines = URL(fileURLWithPath: try value(flag))
            case "--line-lag": options.lineLag = try number(flag)
            case "--language": options.language = try value(flag)
            case "--attendees": options.attendees = Int(try number(flag))
            case "--events": options.events = URL(fileURLWithPath: try value(flag))
            case "--hud": options.hud = URL(fileURLWithPath: try value(flag))
            case "--seed": options.seed = UInt64(try number(flag))
            case "--no-withholding": options.withholding = false
            case "--baseline-rate": options.baselineRate = try number(flag)
            case "--baseline-level": options.baselineLevelDB = try number(flag)
            case "--engine-lags": options.transcriptCues = false
            case "-h", "--help":
                print(usage)
                exit(0)
            default: throw ReplayError(description: "unknown option \(flag)")
            }
        }
        guard options.recording != nil || (options.mic != nil && options.desktop != nil) else {
            throw ReplayError(description: "give --recording, or both --mic and --desktop")
        }
        return options
    }
}

struct DetectorTally: Encodable {
    var triggers = 0
    var shown = 0
    var litSeconds = 0.0
}

struct ReplaySummary: Encodable {
    let audioSeconds: Double
    let wallSeconds: Double
    let realtimeFactor: Double
    let preset: String
    let ownSpeechSeconds: Double
    let articulationRate: Double?
    let levelDB: Double?
    let gateShare: [String: Double]
    let detectors: [String: DetectorTally]
    let gaps: [String: Int]
    let clips: [String: Int]
    let energyShownSeconds: Double
    let linesFed: Int
}

func run(_ options: Options) throws -> ReplaySummary {
    let mic: ChannelReader
    let desktop: ChannelReader
    if let recording = options.recording {
        desktop = try ChannelReader(url: recording, channel: 0, offsetSeconds: options.desktopOffset)
        mic = try ChannelReader(url: recording, channel: 1, offsetSeconds: 0)
    } else if let micURL = options.mic, let desktopURL = options.desktop {
        mic = try ChannelReader(url: micURL, channel: nil, offsetSeconds: 0)
        desktop = try ChannelReader(url: desktopURL, channel: nil, offsetSeconds: options.desktopOffset)
    } else {
        throw ReplayError(description: Options.usage)
    }

    var lines: [ReplayLine] = []
    if let url = options.lines {
        lines = try JSONDecoder().decode([ReplayLine].self, from: Data(contentsOf: url))
        lines.sort { $0.end < $1.end }
    }

    var config = CoachConfig(language: options.language)
    config.preset = CoachPreset.pick(attendeeCount: options.attendees)
    config.withholding = options.withholding
    config.transcriptCues = options.transcriptCues
    config.baselineRate = options.baselineRate
    config.baselineLevelDB = options.baselineLevelDB
    let coach = VoiceCoach(config: config, random: SeededRandom(state: options.seed))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var eventsOut: FileHandle?
    if let url = options.events {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        eventsOut = try FileHandle(forWritingTo: url)
    }
    var hudOut: FileHandle?
    if let url = options.hud {
        FileManager.default.createFile(atPath: url.path, contents: Data("t\tgate\tenergy\tcues\ttalkShare\n".utf8))
        hudOut = try FileHandle(forWritingTo: url)
        hudOut?.seekToEndOfFile()
    }

    var tallies: [String: DetectorTally] = [:]
    var gateSums: [String: Double] = [:]
    var gateSamples = 0
    var gaps: [String: Int] = [:]
    var clips: [String: Int] = [:]
    var energyShown = 0.0
    var lastHUD: CoachHUDState?
    var nextLine = 0
    var micBlock: [Float] = []
    var desktopBlock: [Float] = []
    var t = 0.0
    let started = Date()

    while !mic.finished {
        t += options.step
        try desktop.read(through: t, into: &desktopBlock)
        try mic.read(through: t, into: &micBlock)
        if !desktopBlock.isEmpty {
            desktopBlock.withUnsafeBufferPointer { coach.ingest(.desktop, $0, sampleRate: desktop.rate) }
        }
        if !micBlock.isEmpty {
            micBlock.withUnsafeBufferPointer { coach.ingest(.mic, $0, sampleRate: mic.rate) }
        }
        while nextLine < lines.count, lines[nextLine].end + options.lineLag <= t {
            let line = lines[nextLine]
            coach.ingest(CoachLine(time: line.start, text: line.text, isOwn: line.isOwn))
            nextLine += 1
        }
        let output = coach.advance()
        for event in output.events {
            if let eventsOut {
                var data = try encoder.encode(event)
                data.append(0x0A)
                eventsOut.write(data)
            }
            switch event.kind {
            case .trigger:
                guard let detector = event.detector else { break }
                tallies[detector.rawValue, default: DetectorTally()].triggers += 1
                if event.shown == true { tallies[detector.rawValue, default: DetectorTally()].shown += 1 }
            case .sample where event.note == "gate":
                gateSamples += 1
                for (state, share) in event.values { gateSums[state, default: 0] += share }
            case .gap:
                let note = event.note ?? "gap"
                gaps[note.hasPrefix("system audio realigned") ? "system audio realigned" : note, default: 0] += 1
            case .clip:
                clips[event.note ?? "clip", default: 0] += 1
            default:
                break
            }
        }
        let hud = output.hud
        for cue in hud.litCues { tallies[cue.rawValue, default: DetectorTally()].litSeconds += options.step }
        if hud.energy != nil { energyShown += options.step }
        if hud != lastHUD, let hudOut {
            let energy = hud.energy.map { String(format: "%.3f", $0) } ?? ""
            let cues = hud.litCues.map(\.rawValue).sorted().joined(separator: ",")
            let share = hud.talkShare.map { String(format: "%.3f", $0) } ?? ""
            hudOut.write(Data(String(format: "%.2f\t%@\t%@\t%@\t%@\n", t, hud.gate.rawValue, energy, cues, share).utf8))
        }
        lastHUD = hud
    }
    try eventsOut?.close()
    try hudOut?.close()

    let wall = Date().timeIntervalSince(started)
    let summary = coach.finish()
    var gateShare: [String: Double] = [:]
    if gateSamples > 0 {
        for (state, sum) in gateSums { gateShare[state] = (sum / Double(gateSamples) * 1000).rounded() / 1000 }
    }
    return ReplaySummary(
        audioSeconds: t,
        wallSeconds: wall,
        realtimeFactor: wall > 0 ? t / wall : 0,
        preset: config.preset.rawValue,
        ownSpeechSeconds: summary.ownSpeechSeconds,
        articulationRate: summary.articulationRate,
        levelDB: summary.levelDB,
        gateShare: gateShare,
        detectors: tallies,
        gaps: gaps,
        clips: clips,
        energyShownSeconds: energyShown,
        linesFed: nextLine
    )
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let summary = try run(options)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(summary), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("coach-replay: \(error)\n".utf8))
    exit(1)
}
