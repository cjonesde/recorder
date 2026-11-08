import Foundation

final class MainThreadHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tobi.Recorder.heartbeat", qos: .utility)
    private let interval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?
    private var pendingSince: TimeInterval?
    private var longest: Double = 0

    init(interval: DispatchTimeInterval = .milliseconds(100)) {
        self.interval = interval
    }

    var longestStall: Double {
        lock.withLock {
            guard let pendingSince else { return longest }
            return max(longest, Self.now() - pendingSince)
        }
    }

    func resetLongest() {
        lock.withLock {
            longest = 0
            if pendingSince != nil { pendingSince = Self.now() }
        }
    }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            pendingSince = nil
        }
    }

    private func tick() {
        let now = Self.now()
        let shouldPing: Bool = lock.withLock {
            if let pendingSince {
                longest = max(longest, now - pendingSince)
                return false
            }
            pendingSince = now
            return true
        }
        guard shouldPing else { return }
        DispatchQueue.main.async { [weak self] in self?.pong() }
    }

    private func pong() {
        let now = Self.now()
        lock.withLock {
            guard let pendingSince else { return }
            longest = max(longest, now - pendingSince)
            self.pendingSince = nil
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
