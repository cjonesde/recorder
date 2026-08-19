import Foundation
import Observation
import os
import WhisperKit

/// Load and download progress for one model.
enum ModelLoadState: Equatable {
    case unloaded
    case notDownloaded(String)
    case downloading(String, Double)
    case loading(String)
    case ready
    case failed(String)
}

/// Owns exactly one model instance: its download, its load state machine, and
/// serialized access to it. Generic over the pipe type so the state machine can be
/// tested without constructing a real model.
@MainActor
@Observable
final class ModelHost<Pipe: AnyObject> {

    enum HostError: LocalizedError {
        case modelNotReady(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady(let detail):
                return "Transcription model is not ready: \(detail)"
            }
        }
    }

    var state: ModelLoadState = .unloaded

    /// The model the user selected, which may still be downloading or have failed.
    var selectedModel: String = WhisperModelOption.defaultModelID

    /// The model actually loaded and answering transcriptions, nil before the first
    /// successful load.
    var loadedModel: String?

    /// Set when switching models failed and the previous model was kept.
    var loadFailureMessage: String?

    @ObservationIgnored private let isDownloadedCheck: (String) -> Bool
    @ObservationIgnored private let downloadModel: (String, @escaping (Double) -> Void) async throws -> URL
    @ObservationIgnored private let loadPipe: (String, URL) async throws -> Pipe

    @ObservationIgnored private var pipe: Pipe?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var busy = false

    private static var log: Logger {
        Logger(subsystem: "com.tobi.Recorder", category: "ModelHost")
    }

    init(
        isDownloaded: @escaping (String) -> Bool,
        download: @escaping (String, @escaping (Double) -> Void) async throws -> URL,
        load: @escaping (String, URL) async throws -> Pipe
    ) {
        self.isDownloadedCheck = isDownloaded
        self.downloadModel = download
        self.loadPipe = load
    }

    /// Load `name`, downloading it first when missing and allowed. The previously
    /// loaded model keeps serving until the new one is ready, and is kept when the
    /// switch fails, so a bad download never takes down a working setup.
    func loadModel(_ name: String, downloadIfNeeded: Bool) async {
        selectedModel = name

        switch state {
        case .ready where loadedModel == name:
            return
        case .downloading(let inFlight, _) where inFlight == name:
            return
        case .loading(let inFlight) where inFlight == name:
            return
        case .notDownloaded(let pending) where pending == name && !downloadIfNeeded:
            return
        default:
            break
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadFailureMessage = nil

        let onDisk = isDownloadedCheck(name)
        if !onDisk && !downloadIfNeeded {
            if pipe == nil {
                state = .notDownloaded(name)
            }
            return
        }

        do {
            let folder: URL
            if onDisk {
                folder = try await downloadModel(name, { _ in })
            } else {
                state = .downloading(name, 0)
                folder = try await downloadModel(name, { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.state = .downloading(name, fraction)
                    }
                })
            }
            guard loadGeneration == generation else { return }

            state = .loading(name)
            let loaded = try await loadPipe(name, folder)
            guard loadGeneration == generation else { return }
            pipe = loaded
            loadedModel = name
            state = .ready
        } catch {
            guard loadGeneration == generation else { return }
            Self.log.error("model load failed: \(error.localizedDescription)")
            if pipe != nil, let previous = loadedModel {
                state = .ready
                loadFailureMessage = "Could not switch to \(WhisperModelOption.label(for: name)): \(error.localizedDescription). Still using \(WhisperModelOption.label(for: previous))."
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Wait until a model is loaded, kicking off a load when idle or after a failure.
    func awaitReady(timeout: TimeInterval = 600) async throws -> Pipe {
        switch state {
        case .notDownloaded, .unloaded, .failed:
            await loadModel(selectedModel, downloadIfNeeded: true)
        default:
            break
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pipe, case .ready = state { return pipe }
            if case .failed(let message) = state {
                throw HostError.modelNotReady(message)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw HostError.modelNotReady("timed out waiting for the model to load")
    }

    /// Run `body` with exclusive use of the pipe. The model carries mutable decode
    /// state, so one host must never decode twice at once.
    func withPipe<T>(_ body: (Pipe) async throws -> T) async throws -> T {
        while busy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        busy = true
        defer { busy = false }
        let pipe = try await awaitReady()
        return try await body(pipe)
    }
}

typealias WhisperModelHost = ModelHost<WhisperKit>
