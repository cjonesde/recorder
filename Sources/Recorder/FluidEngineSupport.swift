import Foundation

final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var timer: Task<Void, Never>?

    func arm(_ continuation: CheckedContinuation<T?, Never>, work: Task<T, Never>, timeout: Duration) {
        lock.withLock { self.continuation = continuation }
        let timer = Task.detached { [self] in
            try? await Task.sleep(for: timeout)
            resume(nil)
        }
        lock.withLock { self.timer = timer }
        Task.detached { [self] in resume(await work.value) }
    }

    private func resume(_ value: T?) {
        let pending: (CheckedContinuation<T?, Never>, Task<Void, Never>?)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            return (continuation, timer)
        }
        guard let pending else { return }
        if value != nil { pending.1?.cancel() }
        pending.0.resume(returning: value)
    }
}

enum FluidEngineSupport {
    static var modelsDirectory: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("Recorder", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    static func value<T: Sendable>(of work: Task<T, Never>, within timeout: Duration) async -> T? {
        let gate = FirstResult<T>()
        return await withCheckedContinuation { continuation in
            gate.arm(continuation, work: work, timeout: timeout)
        }
    }

    static func bytesOnDisk(_ directory: URL) -> Int64? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
