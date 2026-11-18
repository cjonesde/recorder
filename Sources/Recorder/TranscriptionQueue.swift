import Foundation
import Observation

enum QueuedJobOutcome: Equatable {
    case finished
    case interrupted
}

@MainActor
@Observable
final class TranscriptionQueue<Job: Identifiable> {

    private(set) var running: Job?
    private(set) var waiting: [Job] = []
    private(set) var isHeld = false

    @ObservationIgnored var perform: (@MainActor (Job) async -> QueuedJobOutcome)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var count: Int { waiting.count + (running == nil ? 0 : 1) }

    func contains(_ id: Job.ID) -> Bool {
        running?.id == id || waiting.contains { $0.id == id }
    }

    func enqueue(_ job: Job) {
        guard !contains(job.id) else { return }
        waiting.append(job)
        startNext()
    }

    func hold() {
        isHeld = true
        task?.cancel()
    }

    func release() {
        isHeld = false
        startNext()
    }

    private func startNext() {
        guard !isHeld, task == nil, let perform, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = job
        task = Task { [weak self] in
            let outcome = await perform(job)
            self?.finish(job, outcome)
        }
    }

    private func finish(_ job: Job, _ outcome: QueuedJobOutcome) {
        running = nil
        task = nil
        if outcome == .interrupted {
            waiting.insert(job, at: 0)
        }
        startNext()
    }
}

enum TranscriptionQueueSummary {
    static func text(running: String?, waiting: Int, recording: Bool) -> String? {
        if recording {
            guard waiting > 0 else { return nil }
            return waiting == 1
                ? "1 local transcription waits until this recording ends"
                : "\(waiting) local transcriptions wait until this recording ends"
        }
        guard let running else { return nil }
        let base = "Transcribing “\(running)” locally"
        return waiting > 0 ? "\(base) · \(waiting) waiting" : base
    }
}
