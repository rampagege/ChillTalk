import Foundation

/// One dictation's worth of speech recognition.
///
/// Audio (16 kHz, mono, 16-bit little-endian PCM) is pushed with `append` while the user is
/// still speaking, so streaming providers can transcribe in parallel with recording.
/// All methods may be called from any thread. `finish`'s completion and `onError` are
/// always delivered on the main queue, at most once per session.
protocol ASRSession: AnyObject {
    /// Called on the main queue if the session fails before `finish` is requested.
    var onError: ((Error) -> Void)? { get set }
    /// Running transcript while recording (main queue). Only streaming providers send it.
    var onPartialTranscript: ((String) -> Void)? { get set }
    func start()
    func append(_ pcm: Data)
    func finish(completion: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

/// Domain hints that help a provider recognize the user's terms.
struct RecognitionHints {
    /// Term → weight (1…5, or 50 for a "super" hot word).
    var hotwords: [String: Int] = [:]
    /// Short description of what the user talks about.
    var context: String = ""
    var language: DictationLanguage = .zhHans
    /// English words expected inside non-English speech.
    var mixEnglish: Bool = true

    /// Language hint codes for providers that take a list (DashScope, Soniox).
    var languageCodes: [String] {
        var codes = [language.hintCode]
        if mixEnglish && language != .en { codes.append("en") }
        return codes
    }

    /// Single language for upload-only providers; nil lets the model auto-detect mixed speech.
    var singleLanguage: String? {
        (mixEnglish && language != .en) ? nil : language.whisperCode
    }

    static let none = RecognitionHints()
}

/// When recognition happens: while the user speaks (live text, fastest result) or on the
/// whole recording after they stop (cheaper, sees full context, waveform-only HUD).
enum RecognitionMode: String, CaseIterable, Identifiable {
    case realtime
    case batch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtime: return String(localized: "实时")
        case .batch: return String(localized: "说完再识别")
        }
    }
}

enum ASRProviderType: String, CaseIterable {
    // Raw value is persisted in UserDefaults; keep it stable.
    case dashScope = "DashScope Fun-ASR"
    case deepgram = "Deepgram Nova-3"
    case openAIWhisper = "OpenAI Whisper"
    case openRouter = "OpenRouter（实验）"
    case soniox = "Soniox"
    case assemblyAI = "AssemblyAI"

    var displayName: String {
        switch self {
        case .dashScope: return String(localized: "千问 / 阿里云百炼")
        case .openRouter: return String(localized: "OpenRouter（实验）")
        default: return rawValue
        }
    }

    var supportsRealtime: Bool {
        switch self {
        case .dashScope, .deepgram, .soniox, .assemblyAI: return true
        case .openAIWhisper, .openRouter: return false
        }
    }

    var supportsBatch: Bool {
        switch self {
        case .dashScope, .assemblyAI, .openAIWhisper, .openRouter: return true
        case .deepgram, .soniox: return false
        }
    }

    /// The preferred mode if this provider supports it, otherwise the one it does.
    func effectiveMode(_ preferred: RecognitionMode) -> RecognitionMode {
        switch preferred {
        case .realtime: return supportsRealtime ? .realtime : .batch
        case .batch: return supportsBatch ? .batch : .realtime
        }
    }

    /// Rough list price in CNY per audio second, for the usage estimate only.
    /// USD prices converted at ≈7.1.
    func estimatedYuanPerSecond(_ mode: RecognitionMode) -> Double {
        switch (self, mode) {
        case (.dashScope, .batch): return 0.00022                  // qwen3-asr-flash
        case (.assemblyAI, .batch): return (0.21 + 0.05) * 7.1 / 3600  // Universal-3.5 Pro + keyterms
        default: break
        }
        switch self {
        case .dashScope: return 0.00033            // ¥0.00033/s
        case .deepgram: return 0.0077 * 7.1 / 60   // $0.0077/min streaming
        case .openAIWhisper, .openRouter: return 0.006 * 7.1 / 60  // $0.006/min
        case .soniox: return 0.12 * 7.1 / 3600      // $0.12/h real-time
        case .assemblyAI: return 0.45 * 7.1 / 3600  // $0.45/h Universal-3.6 Pro real-time
        }
    }

    var shortName: String {
        switch self {
        case .dashScope: return "DashScope"
        case .deepgram: return "Deepgram"
        case .openAIWhisper: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .soniox: return "Soniox"
        case .assemblyAI: return "AssemblyAI"
        }
    }

    /// `hints` are used by providers that support them (DashScope, Soniox); others ignore them.
    func makeSession(apiKey: String, hints: RecognitionHints = .none, mode: RecognitionMode = .realtime) -> ASRSession {
        switch (self, effectiveMode(mode)) {
        case (.dashScope, .batch): return QwenBatchASR(apiKey: apiKey, hints: hints)
        case (.assemblyAI, .batch): return AssemblyAIBatchASR(apiKey: apiKey, hints: hints)
        default: break
        }
        switch self {
        case .dashScope: return DashScopeASR(apiKey: apiKey, model: SettingsManager.shared.getDashScopeASRModel(),
                                             hints: hints)
        case .deepgram: return DeepgramASR(apiKey: apiKey, hints: hints)
        case .openAIWhisper: return OpenAICompatibleASR.openAIWhisper(apiKey: apiKey, language: hints.singleLanguage)
        case .openRouter: return OpenAICompatibleASR.openRouter(apiKey: apiKey, language: hints.singleLanguage)
        case .soniox: return SonioxASR(apiKey: apiKey, hints: hints)
        case .assemblyAI: return AssemblyAIASR(apiKey: apiKey, hints: hints)
        }
    }
}

enum ASRError: LocalizedError {
    case invalidResponse
    case networkError(String)
    case apiError(String)
    case invalidAPIKey
    case timeout
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "服务返回了无法解析的响应")
        case .networkError(let msg):
            return String(localized: "网络错误：\(msg)")
        case .apiError(let msg):
            return String(localized: "API 错误：\(msg)")
        case .invalidAPIKey:
            return String(localized: "API 密钥无效或无权限")
        case .timeout:
            return String(localized: "等待识别结果超时")
        case .noTranscript:
            return String(localized: "没有识别到语音")
        }
    }
}

// MARK: - Segment joining

enum TranscriptJoiner {
    /// Joins finalized sentence segments. CJK text is concatenated directly; a space is
    /// inserted only where two Latin-script segments would otherwise run together.
    static func join(_ segments: [String]) -> String {
        var result = ""
        for raw in segments {
            let segment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = segment.unicodeScalars.first,
               isLatinOrTerminal(last), isLatinOrDigit(first) {
                result += " "
            }
            result += segment
        }
        return result
    }

    /// Removes spaces that sit between two CJK characters ("你好 世界" → "你好世界").
    static func removingSpacesBetweenCJK(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (i, s) in scalars.enumerated() {
            if s == " ", i > 0, i + 1 < scalars.count, isCJK(scalars[i - 1]), isCJK(scalars[i + 1]) {
                continue
            }
            result.append(s)
        }
        return String(result)
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    private static func isLatinOrDigit(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && CharacterSet.alphanumerics.contains(s)
    }

    private static func isLatinOrTerminal(_ s: Unicode.Scalar) -> Bool {
        isLatinOrDigit(s) || ".,!?;:".unicodeScalars.contains(s)
    }
}

// MARK: - Buffered (HTTP upload) sessions

/// Collects audio while recording and uploads it in one request on `finish`.
/// Subclasses implement `upload`.
class BufferedASRSession: ASRSession {
    var onError: ((Error) -> Void)?
    var onPartialTranscript: ((String) -> Void)?

    private let lock = NSLock()
    private var buffer = Data()
    private var isCancelled = false
    private var uploadTask: URLSessionTask?

    func start() {}

    func append(_ pcm: Data) {
        lock.lock()
        buffer.append(pcm)
        lock.unlock()
    }

    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        let audio = buffer
        buffer = Data()
        let cancelled = isCancelled
        lock.unlock()
        guard !cancelled else { return }

        let task = upload(pcm: audio) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.isCancelledNow else { return }
                completion(result)
            }
        }
        if let task = task { track(task) }
    }

    /// Multi-step uploads register each request so `cancel()` stops whichever is running.
    func track(_ task: URLSessionTask) {
        lock.lock()
        uploadTask = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        buffer = Data()
        let task = uploadTask
        lock.unlock()
        task?.cancel()
    }

    var isCancelledNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Override: send `pcm` and call `completion` exactly once (any thread).
    func upload(pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        fatalError("Subclasses must override upload(pcm:completion:)")
    }
}

// MARK: - WebSocket streaming sessions

/// Base class for providers that stream audio over a WebSocket while the user speaks.
///
/// Every piece of mutable state, every delegate callback and every receive/send completion
/// runs on `queue`, so subclasses never need their own locking.
class WebSocketASRSession: NSObject, ASRSession, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    var onError: ((Error) -> Void)?
    /// Called on the main queue once the provider is ready to accept audio. Used by the
    /// settings "测试连接" check.
    var onReady: (() -> Void)?
    var onPartialTranscript: ((String) -> Void)?

    let queue = DispatchQueue(label: "com.chilltalk.asr.websocket")
    private(set) var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var completion: ((Result<String, Error>) -> Void)?
    private var pendingError: Error?
    private var isDone = false
    private var timeoutWork: DispatchWorkItem?
    private(set) var finishRequested = false

    /// Seconds to wait for the final result after `finish` before giving up.
    var finishTimeout: TimeInterval { 10 }

    // MARK: Subclass hooks (all called on `queue`)

    func makeRequest() -> URLRequest? { fatalError("Subclasses must override makeRequest()") }
    /// Called right after the socket is created, before any audio can be queued. Messages
    /// sent here are guaranteed to go first.
    func socketCreated() {}
    /// Default: the socket being open means ready. Override (without calling super) when the
    /// provider needs a handshake first, and call `signalReady()` when it completes.
    func socketDidOpen() { signalReady() }
    func handleMessage(_ text: String) {}
    func sendAudio(_ pcm: Data) {}
    func sendFinish() {}
    func currentTranscript() -> String { "" }

    // MARK: ASRSession

    func start() {
        queue.async {
            guard let request = self.makeRequest() else {
                self.fail(ASRError.networkError(String(localized: "无效的服务地址")))
                return
            }
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = self.queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
            let socket = session.webSocketTask(with: request)
            self.urlSession = session
            self.socket = socket
            socket.resume()
            self.socketCreated()
            self.receiveNext()
        }
    }

    func append(_ pcm: Data) {
        queue.async {
            guard !self.isDone, !self.finishRequested, self.pendingError == nil else { return }
            self.sendAudio(pcm)
        }
    }

    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard !self.isDone else { return }
            self.completion = completion
            if let error = self.pendingError {
                self.deliver(.failure(error))
                return
            }
            self.finishRequested = true
            self.sendFinish()
            // Cancelled in teardown, so holding self here is bounded by the timeout.
            let work = DispatchWorkItem {
                let text = self.currentTranscript()
                self.deliver(text.isEmpty ? .failure(ASRError.timeout) : .success(text))
            }
            self.timeoutWork = work
            self.queue.asyncAfter(deadline: .now() + self.finishTimeout, execute: work)
        }
    }

    func cancel() {
        queue.async {
            self.completion = nil
            self.onError = nil
            self.onPartialTranscript = nil
            self.isDone = true
            self.teardown()
        }
    }

    // MARK: Helpers for subclasses (call on `queue`)

    func send(text: String) {
        socket?.send(.string(text)) { [weak self] error in
            if let error = error { self?.fail(ASRError.networkError(error.localizedDescription)) }
        }
    }

    func send(data: Data) {
        socket?.send(.data(data)) { [weak self] error in
            if let error = error { self?.fail(ASRError.networkError(error.localizedDescription)) }
        }
    }

    func signalReady() {
        guard let onReady = onReady else { return }
        self.onReady = nil
        DispatchQueue.main.async { onReady() }
    }

    /// Reports `currentTranscript()` to `onPartialTranscript`. Call after each result.
    func publishPartial() {
        guard !isDone, let onPartial = onPartialTranscript else { return }
        let text = currentTranscript()
        DispatchQueue.main.async { onPartial(text) }
    }

    /// The provider has sent its last result.
    func complete() {
        let text = currentTranscript()
        deliver(text.isEmpty ? .failure(ASRError.noTranscript) : .success(text))
    }

    func fail(_ error: Error) {
        guard !isDone else { return }
        if completion != nil {
            deliver(.failure(error))
        } else if pendingError == nil {
            // Failed while still recording: remember it for `finish` and tell the app now.
            pendingError = error
            teardown()
            let onError = self.onError
            DispatchQueue.main.async { onError?(error) }
        }
    }

    // MARK: Private

    private func receiveNext() {
        socket?.receive { [weak self] result in
            guard let self = self, !self.isDone else { return }
            switch result {
            case .success(.string(let text)):
                self.handleMessage(text)
                self.receiveNext()
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                self.receiveNext()
            case .success:
                self.receiveNext()
            case .failure(let error):
                self.handleSocketError(error)
            }
        }
    }

    private func handleSocketError(_ error: Error) {
        if let response = socket?.response as? HTTPURLResponse, [401, 403].contains(response.statusCode) {
            fail(ASRError.invalidAPIKey)
        } else if finishRequested {
            // Some servers simply close after the last result.
            complete()
        } else {
            fail(ASRError.networkError(error.localizedDescription))
        }
    }

    private func deliver(_ result: Result<String, Error>) {
        guard !isDone else { return }
        isDone = true
        let completion = self.completion
        self.completion = nil
        teardown()
        DispatchQueue.main.async { completion?(result) }
    }

    private func teardown() {
        timeoutWork?.cancel()
        timeoutWork = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        // URLSession retains its delegate until invalidated.
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        socketDidOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if finishRequested {
            complete()
        } else {
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(closeCode.rawValue)"
            fail(ASRError.networkError(String(localized: "连接被服务器关闭（\(detail)）")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        handleSocketError(error)
    }
}

// MARK: - HTTP helpers

enum HTTPResponseCheck {
    /// Returns an error for non-2xx responses, preferring the API's own error message.
    static func error(for response: URLResponse?, data: Data?) -> Error? {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 { return ASRError.invalidAPIKey }
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return ASRError.apiError("HTTP \(http.statusCode): \(message)")
        }
        return ASRError.apiError("HTTP \(http.statusCode)")
    }
}

enum WAVEncoder {
    /// Wraps raw 16 kHz mono 16-bit PCM in a WAV container.
    static func wav(fromPCM pcm: Data, sampleRate: UInt32 = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)

        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(numChannels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        wav.append(contentsOf: Array("data".utf8))
        append(dataSize)
        wav.append(pcm)
        return wav
    }
}
