import Foundation
import WhisperKit

/// Where WhisperKit models live on disk, and how to build a host that loads them.
enum WhisperModelStorage {

    /// ~/Library/Application Support/Recorder/WhisperModels
    static var base: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("Recorder", isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    static func localFolder(for name: String) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func isDownloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: localFolder(for: name).appendingPathComponent("TextDecoder.mlmodelc").path
        )
    }

    @MainActor
    static func makeHost() -> WhisperModelHost {
        WhisperModelHost(
            isDownloaded: { isDownloaded($0) },
            download: { name, report in
                if isDownloaded(name) { return localFolder(for: name) }
                return try await WhisperKit.download(
                    variant: name,
                    downloadBase: base,
                    progressCallback: { progress in report(progress.fractionCompleted) }
                )
            },
            load: { name, folder in
                let config = WhisperKitConfig(
                    model: name,
                    downloadBase: base,
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: false
                )
                return try await WhisperKit(config)
            }
        )
    }
}
