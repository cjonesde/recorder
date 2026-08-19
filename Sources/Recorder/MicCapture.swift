import Foundation
import AVFoundation
import os

/// Microphone capture via `AVAudioEngine`'s input node, written MONO to `mic.caf`.
///
/// Design notes (see research-notes "mic-capture-and-sync"):
/// - We deliberately run this as an *independent* engine from the system-audio tap.
///   The model records both sources to separate CAFs and `StereoMixer` aligns them
///   afterward using each stream's first-sample host time (the "merge-on-stop"
///   fallback path). That is why `start()` records `firstHostTime` from the very
///   first delivered buffer's `AVAudioTime`.
/// - The input format is taken LIVE from the hardware (`inputFormat(forBus:)`) — we
///   never hardcode 44.1/48 kHz, or AVAudioEngine asserts on a sample-rate mismatch
///   (Bluetooth mics / AirPods commonly run 16 kHz mono input).
/// - The tap block fires on a real-time audio thread. This class only *invokes* its
///   `onLevelDB` / `onFatalError` callbacks from that thread; the model is responsible
///   for hopping to main before touching UI/model state.
///
/// Concurrency: written for Swift 5 language mode. Mutable state touched from both the
/// audio thread (tap block) and the main thread (`start`/`stop`/`setPaused`) is guarded
/// by `OSAllocatedUnfairLock`.
final class MicCapture {

    /// dBFS per buffer (computed via `RMSMeter`). Called on the audio thread.
    var onLevelDB: ((Float) -> Void)?
    /// Called on an arbitrary thread when the engine fails fatally.
    var onFatalError: ((Error) -> Void)?
    /// Mono samples that were just written to disk (post-downmix), with the
    /// capture sample rate. Called on the audio thread; the pointer is only
    /// valid for the duration of the call. Not invoked while paused.
    var onSamples: ((UnsafePointer<Float>, Int, Double) -> Void)?

    // MARK: - Errors

    enum MicError: LocalizedError {
        case couldNotCreateFile(URL, underlying: Error)
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFile(let url, let underlying):
                return "Could not open mic file at \(url.lastPathComponent): \(underlying.localizedDescription)"
            case .invalidInputFormat:
                return "Microphone reported an unusable input format (0 channels or 0 Hz)."
            }
        }
    }

    // MARK: - Audio objects

    /// The engine is created lazily per `start()` so a stop/start cycle gets a fresh
    /// graph (and re-reads the current input device format).
    private let engine = AVAudioEngine()

    // MARK: - Shared, lock-protected state

    /// Guards everything below; locked briefly inside the real-time tap block.
    private let lock = OSAllocatedUnfairLock()

    /// Destination file. Created on `start`, finalized (set nil) on `stop`.
    private var file: AVAudioFile?

    /// When true, the tap block computes meters but does NOT write to disk.
    private var paused = false

    /// Host time (mach_absolute_time domain) of the first buffer we wrote. `nil` until
    /// the first non-paused buffer arrives.
    private var firstHostTime: UInt64?

    /// Sample rate actually used by the input hardware (and thus the file).
    private var sampleRate: Double = 0

    /// Total frames written to disk.
    private var frameCount: AVAudioFramePosition = 0

    /// Whether a tap is currently installed / engine running.
    private var running = false

    /// Mono Float32 format at the current hardware rate, used to downmix a
    /// multi-channel input buffer. Re-derived whenever the route changes.
    private var downmixFormat: AVAudioFormat?

    /// Converts mono input to `sampleRate`, the file's rate pinned at `start`, when the
    /// hardware renegotiates mid-recording.
    private var resampler: RealtimeResampler?

    /// Reusable canonical-rate destination for `resampler` output.
    private var resampleBuffer: AVAudioPCMBuffer?

    // MARK: - Route changes

    private var configObserver: NSObjectProtocol?

    /// Serializes reconfiguration against itself; `running` guards it against `stop`.
    private let reconfigureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.tobi.Recorder.MicCapture.reconfigure"
        return queue
    }()

    private static let tapBufferSize: AVAudioFrameCount = 4096

    private static let resampleCapacity: AVAudioFrameCount = 32_768

    private static let log = Logger(subsystem: "com.tobi.Recorder", category: "MicCapture")

    // MARK: - Authorization

    /// Checks / requests microphone (audio) capture permission.
    /// On macOS the capture-permission path is `AVCaptureDevice` (the
    /// `AVAudioSession.requestRecordPermission` API is iOS-only).
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Start

    /// Begin capturing the microphone, writing MONO Float32 to `url` (CAF).
    func start(writingTo url: URL?) throws {
        // Pull the LIVE hardware input format — never hardcode the sample rate.
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw MicError.invalidInputFormat
        }

        // We always write a single (mono) channel; downmix happens in the tap block
        // when the input has more than one channel.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicError.invalidInputFormat
        }

        // Open the destination file. Float32 mono PCM in a CAF container is cheap and
        // append-friendly; writing the file's processing format == monoFormat avoids
        // any implicit conversion on write.
        var outFile: AVAudioFile?
        if let url {
            do {
                outFile = try AVAudioFile(
                    forWriting: url,
                    settings: monoFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw MicError.couldNotCreateFile(url, underlying: error)
            }
        }

        let canonicalRate = inputFormat.sampleRate
        let converter = RealtimeResampler(outputRate: canonicalRate)
        converter.reset(inputRate: inputFormat.sampleRate)

        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: Self.resampleCapacity
        ) else {
            throw MicError.invalidInputFormat
        }

        // Reset shared state under the lock before the tap can fire.
        lock.withLock {
            self.file = outFile
            self.paused = false
            self.firstHostTime = nil
            self.sampleRate = canonicalRate
            self.frameCount = 0
            self.running = true
            self.downmixFormat = monoFormat
            self.resampler = converter
            self.resampleBuffer = scratch
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: reconfigureQueue
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        // Install the tap on the INPUT format (passing `nil` lets the engine use the
        // node's own format, which is exactly inputFormat). Buffer size 4096 per contract.
        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { [weak self] buffer, when in
            self?.handleBuffer(buffer, when: when)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Roll back so a failed start leaves us in a clean state.
            inputNode.removeTap(onBus: 0)
            removeConfigObserver()
            lock.withLock {
                self.file = nil
                self.running = false
                self.downmixFormat = nil
                self.resampler = nil
                self.resampleBuffer = nil
            }
            throw error
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
    }

    /// Re-read the hardware format, retarget the resampler and reinstall the tap. Runs
    /// serialized on `reconfigureQueue`, with the tap removed first so conversion state
    /// is only mutated while no buffers can arrive.
    private func handleConfigurationChange() {
        guard lock.withLock({ running }) else { return }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let newFormat = inputNode.inputFormat(forBus: 0)
        guard newFormat.channelCount > 0, newFormat.sampleRate > 0,
              let newDownmix = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: newFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              )
        else {
            Self.log.error("mic route changed to an unusable format; capture cannot continue")
            lock.withLock { self.running = false }
            onFatalError?(MicError.invalidInputFormat)
            return
        }

        let canonical: Double = lock.withLock {
            self.downmixFormat = newDownmix
            self.resampler?.reset(inputRate: newFormat.sampleRate)
            return self.sampleRate
        }

        if newFormat.sampleRate != canonical {
            Self.log.warning(
                "mic route changed to \(newFormat.sampleRate, privacy: .public) Hz; resampling to the recording's \(canonical, privacy: .public) Hz"
            )
        } else {
            Self.log.info("mic route changed, rate unchanged at \(canonical, privacy: .public) Hz")
        }

        inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: newFormat) { [weak self] buffer, when in
            self?.handleBuffer(buffer, when: when)
        }

        engine.prepare()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Self.log.error("mic engine restart after route change failed: \(error.localizedDescription)")
                lock.withLock { self.running = false }
                onFatalError?(error)
                return
            }
        }

        if !lock.withLock({ running }) {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Real-time tap block

    /// Called on a real-time audio thread for every captured buffer.
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // Always compute a meter level, even while paused, so the UI keeps moving.
        let db = RMSMeter.dBFS(buffer)
        onLevelDB?(db)

        // Determine the host time of this buffer (mach_absolute_time domain).
        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()

        guard buffer.frameLength > 0 else { return }

        let (isRunning, monoFormat, resampler, scratch) = lock.withLock {
            (self.running, self.downmixFormat, self.resampler, self.resampleBuffer)
        }
        guard isRunning, let monoFormat else { return }

        let monoSource: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            monoSource = buffer
        } else if let mono = MicCapture.downmixToMono(buffer, monoFormat: monoFormat) {
            monoSource = mono
        } else {
            // Format we can't handle (e.g. non-Float32 and downmix failed); skip safely.
            return
        }
        guard let src = monoSource.floatChannelData?[0] else { return }

        guard let resampler, !resampler.isPassThrough,
              let scratch, let dst = scratch.floatChannelData?[0]
        else {
            write(monoSource, hostTime: hostTime)
            return
        }

        let capacity = Int(scratch.frameCapacity)
        let chunkLimit = max(1, resampler.maxInputFrames(forOutputCapacity: capacity))
        let frames = Int(monoSource.frameLength)
        var offset = 0
        while offset < frames {
            let chunk = min(frames - offset, chunkLimit)
            let written = resampler.process(src + offset, count: chunk, into: dst, capacity: capacity)
            if written > 0 {
                scratch.frameLength = AVAudioFrameCount(written)
                write(scratch, hostTime: hostTime)
            }
            offset += chunk
        }
    }

    /// Append one canonical-rate mono buffer to disk and forward it to `onSamples`.
    private func write(_ writeBuffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let wrote: Bool = lock.withLock {
            guard self.running, !self.paused else { return false }
            if let file = self.file {
                do {
                    try file.write(from: writeBuffer)
                } catch {
                    self.running = false
                    self.file = nil
                    self.onFatalError?(error)
                    return false
                }
            }
            if self.firstHostTime == nil {
                self.firstHostTime = hostTime
            }
            self.frameCount += AVAudioFramePosition(writeBuffer.frameLength)
            return true
        }

        if wrote, let onSamples, let mono = writeBuffer.floatChannelData?[0] {
            onSamples(mono, Int(writeBuffer.frameLength), writeBuffer.format.sampleRate)
        }
    }

    /// Average all channels of `buffer` into a single mono Float32 buffer with `monoFormat`.
    /// Returns nil if the source isn't Float32-accessible.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0 else {
            return AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1)
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)

        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else {
            return nil
        }
        mono.frameLength = frames
        guard let dst = mono.floatChannelData?[0] else { return nil }

        let n = Int(frames)
        if channelCount == 1 {
            // Straight copy (covers the rare case the caller passed a 1-ch non-shortcut buffer).
            dst.update(from: channels[0], count: n)
        } else {
            let inv = 1.0 / Float(channelCount)
            for i in 0..<n {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][i]
                }
                dst[i] = sum * inv
            }
        }
        return mono
    }

    // MARK: - Pause

    /// Stop persisting audio while capture continues. `write` already treats a nil file
    /// as capture-without-persist, so clearing it is enough.
    func stopWriting() {
        lock.withLock { self.file = nil }
    }

    /// Gate writes without tearing down the engine; meters keep updating while paused.
    func setPaused(_ paused: Bool) {
        lock.withLock {
            self.paused = paused
        }
    }

    // MARK: - Stop

    /// Stop the engine, finalize the file, and return what was captured.
    func stop() -> CaptureResult {
        removeConfigObserver()
        reconfigureQueue.waitUntilAllOperationsAreFinished()

        // Stop the running graph first so no more buffers arrive after we drop the file.
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            // Defensive: remove the tap even if the engine never fully started.
            engine.inputNode.removeTap(onBus: 0)
        }

        // Snapshot + finalize state. Setting `file = nil` flushes/closes the AVAudioFile.
        return lock.withLock {
            let result = CaptureResult(
                firstHostTime: self.firstHostTime,
                sampleRate: self.sampleRate,
                frameCount: self.frameCount
            )
            self.running = false
            self.file = nil   // releasing the AVAudioFile finalizes the CAF on disk
            self.downmixFormat = nil
            self.resampler = nil
            self.resampleBuffer = nil
            return result
        }
    }
}
