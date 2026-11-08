import Foundation

final class StreamingInputPump: @unchecked Sendable {
    private let inbox: StreamingAudioInput
    private let deliver: @Sendable (StreamingAudioInput.Chunk) throws -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "com.tobi.Recorder.speechInputPump", qos: .userInitiated)
    private let timerLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(inbox: StreamingAudioInput,
         deliver: @escaping @Sendable (StreamingAudioInput.Chunk) throws -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) {
        self.inbox = inbox
        self.deliver = deliver
        self.onFailure = onFailure
    }

    func start(interval: DispatchTimeInterval = .milliseconds(50)) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, let error = self.drain(flush: false) else { return }
            self.onFailure(error)
        }
        timerLock.withLock { self.timer = timer }
        timer.resume()
    }

    func finish() -> Error? {
        cancelTimer()
        return queue.sync { drain(flush: true) }
    }

    func stop() {
        cancelTimer()
        queue.sync { stopped = true }
    }

    private func cancelTimer() {
        timerLock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    private func drain(flush: Bool) -> Error? {
        guard !stopped else { return nil }
        do {
            while let chunk = try inbox.drain(flush: flush) { try deliver(chunk) }
            return nil
        } catch {
            stopped = true
            return error
        }
    }
}
