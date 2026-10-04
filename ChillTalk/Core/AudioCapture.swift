import Accelerate
import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return String(localized: "已经在录音")
        case .noInputDevice: return String(localized: "没有可用的麦克风")
        case .formatUnavailable: return String(localized: "无法创建音频格式转换")
        }
    }
}

/// Captures microphone audio and converts it to 16 kHz mono 16-bit PCM for cloud ASR.
///
/// The engine is created on the first recording, reused while the user keeps dictating, and
/// released after a few idle minutes to give its audio buffers back. It only runs while
/// recording, so the system mic indicator stays off when idle. Input device changes
/// mid-recording (e.g. AirPods connecting) rebuild the tap with the new format.
final class AudioCapture {
    /// Raw input buffers for Apple live captions. Called on the audio thread.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Input level 0.0…1.0. Called on the audio thread.
    var onAudioLevel: ((Double) -> Void)?
    /// Called on the main queue if recording can't continue after a device change.
    var onError: ((Error) -> Void)?
    /// macOS voice processing: echo cancellation (removes what this Mac is playing),
    /// noise suppression and automatic gain. Applied at the next `startRecording`.
    var voiceProcessingEnabled = false

    private var engineStorage: AVAudioEngine?
    private var releaseWork: DispatchWorkItem?
    /// Idle time after the last recording before the engine is released.
    private static let idleRelease: TimeInterval = 180
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var capturedBytes = 0
    private var pcmSink: ((Data) -> Void)?

    private(set) var isRecording = false
    private var configObserver: NSObjectProtocol?

    init() {}

    /// The engine, created (with its device-change observer) when first needed.
    private var engine: AVAudioEngine {
        if let engine = engineStorage { return engine }
        let engine = AVAudioEngine()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        engineStorage = engine
        return engine
    }

    private func scheduleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isRecording else { return }
            if let observer = self.configObserver { NotificationCenter.default.removeObserver(observer) }
            self.configObserver = nil
            self.engineStorage = nil
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRelease, execute: work)
    }

    deinit {
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// `sink` receives converted 16 kHz PCM chunks on the audio thread while recording.
    func startRecording(sink: @escaping (Data) -> Void) throws {
        guard !isRecording else { throw AudioCaptureError.alreadyRecording }
        releaseWork?.cancel()
        lock.lock()
        capturedBytes = 0
        pcmSink = sink
        lock.unlock()

        do {
            try installTapAndStart()
        } catch where voiceProcessingEnabled {
            // Never let the optional enhancement break recording: retry without it.
            print("⚠️ Voice processing failed (\(error.localizedDescription)), recording without it")
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            do {
                try installTapAndStart(allowVoiceProcessing: false)
            } catch {
                setSink(nil)
                throw error
            }
        } catch {
            setSink(nil)
            throw error
        }
        isRecording = true
    }

    /// Stops recording and returns the captured duration in seconds.
    @discardableResult
    func stopRecording() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        scheduleRelease()

        lock.lock()
        let bytes = capturedBytes
        capturedBytes = 0
        pcmSink = nil
        lock.unlock()
        return Double(bytes) / Double(MemoryLayout<Int16>.size) / targetFormat.sampleRate
    }

    // MARK: - Private

    private func setSink(_ sink: ((Data) -> Void)?) {
        lock.lock()
        pcmSink = sink
        lock.unlock()
    }

    private func installTapAndStart(allowVoiceProcessing: Bool = true) throws {
        let input = engine.inputNode
        try applyVoiceProcessing(to: input, enabled: allowVoiceProcessing && voiceProcessingEnabled)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.formatUnavailable
        }
        // Voice processing can deliver several channels; mix them down to mono.
        converter.downmix = true

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Must be called while the engine is stopped. Voice processing is built for calls, so it
    /// ducks other apps' audio by default; keep that to the minimum.
    private func applyVoiceProcessing(to input: AVAudioInputNode, enabled: Bool) throws {
        guard input.isVoiceProcessingEnabled != enabled else { return }
        try input.setVoiceProcessingEnabled(enabled)
        if enabled {
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            // The voice-processing unit drives input and output together.
            _ = engine.outputNode
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        onAudioLevel?(Self.level(of: buffer))
        onAudioBuffer?(buffer)

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // Hand the buffer over exactly once per call. Returning it again on a second
        // callback would feed duplicate samples into the resampler.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0,
              let channel = output.int16ChannelData else { return }

        let data = Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        capturedBytes += data.count
        let sink = pcmSink
        lock.unlock()
        sink?(data)
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        do {
            try installTapAndStart()
        } catch {
            stopRecording()
            onError?(error)
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return 0 }
        // Map -60 dB…0 dB to 0…1.
        let db = 20 * log10(rms)
        return Double(max(0, min(1, (db + 60) / 60)))
    }
}
