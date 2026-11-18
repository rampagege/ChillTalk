import Foundation

/// AssemblyAI streaming (v3) real-time transcription with AssemblyAI-STT-3.7-Realtime, the model
/// meant for live transcripts nobody has to answer ($0.30/h; the voice-agent variant costs more).
///
/// Protocol: connect with the API key in the `Authorization` header and settings in the
/// query → `Begin` → binary PCM in 50–1000 ms chunks → `{"type":"Terminate"}` → `Turn`
/// messages (one per utterance, refined until `end_of_turn`) → `Termination`.
/// Docs: https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api
final class AssemblyAIASR: WebSocketASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private let endpoint = "wss://streaming.assemblyai.com/v3/ws"
    private let model = "assemblyai-stt-3-7-realtime"

    /// AssemblyAI accepts at most 100 key terms.
    static let maxKeyterms = 100
    /// 100 ms of 16 kHz 16-bit mono; chunks must be 50–1000 ms.
    private static let chunkBytes = 3200
    private static let minChunkBytes = 1600

    private var pending = Data()
    /// Latest transcript per turn, keyed by `turn_order`.
    private var turns: [Int: String] = [:]

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
        super.init()
    }

    override func makeRequest() -> URLRequest? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        var items = [
            URLQueryItem(name: "speech_model", value: model),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
        ]
        if let json = Self.jsonArray(hints.assemblyAILanguages) {
            items.append(URLQueryItem(name: "language_codes", value: json))
        }
        let terms = hints.hotwords.sorted { $0.value > $1.value }.map(\.key).prefix(Self.maxKeyterms)
        if !terms.isEmpty, let json = Self.jsonArray(Array(terms)) {
            items.append(URLQueryItem(name: "keyterms_prompt", value: json))
        }
        components.queryItems = items
        // URLComponents leaves "+" as is, which the server decodes as a space ("C++" → "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// Ready once the server says `Begin` (the key has been accepted by then).
    override func socketDidOpen() {}

    override func sendAudio(_ pcm: Data) {
        pending.append(pcm)
        while pending.count >= Self.chunkBytes {
            send(data: pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
        }
    }

    override func sendFinish() {
        if !pending.isEmpty {
            if pending.count < Self.minChunkBytes {
                pending.append(Data(count: Self.minChunkBytes - pending.count))  // pad with silence
            }
            send(data: pending)
            pending.removeAll()
        }
        send(text: #"{"type":"Terminate"}"#)
    }

    override func currentTranscript() -> String {
        let ordered = turns.keys.sorted().compactMap { turns[$0] }
        return TranscriptJoiner.join(ordered.map(TranscriptJoiner.removingSpacesBetweenCJK))
    }

    override func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let error = json["error"] as? String {
            fail(error.localizedCaseInsensitiveContains("auth") || error.localizedCaseInsensitiveContains("api key")
                 ? ASRError.invalidAPIKey : ASRError.apiError("AssemblyAI: \(error)"))
            return
        }

        switch json["type"] as? String {
        case "Begin":
            signalReady()
        case "Turn":
            let order = json["turn_order"] as? Int ?? turns.count
            turns[order] = json["transcript"] as? String ?? ""
            publishPartial()
        case "Termination":
            complete()
        default:
            break
        }
    }

    private static func jsonArray(_ values: [String]) -> String? {
        guard !values.isEmpty, let data = try? JSONSerialization.data(withJSONObject: values) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension RecognitionHints {
    /// Language codes for AssemblyAI. Cantonese has no separate code there; Chinese covers it.
    var assemblyAILanguages: [String] {
        var languages: [String] = []
        for code in languageCodes.map({ $0 == "yue" ? "zh" : $0 }) where !languages.contains(code) {
            languages.append(code)
        }
        return languages
    }
}

/// AssemblyAI pre-recorded transcription ("说完再识别"): upload → submit → poll.
/// AssemblyAI-STT-3.7 costs less than real-time and sees the whole recording; Universal-2 is the
/// fallback for languages 3.7 doesn't cover.
final class AssemblyAIBatchASR: BufferedASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private let base = "https://api.assemblyai.com/v2"
    /// Pre-recorded AssemblyAI-STT-3.7 accepts up to 1000 key terms.
    static let maxKeyterms = 1000
    private static let pollInterval: TimeInterval = 0.3
    private static let timeout: TimeInterval = 90

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
    }

    override func upload(pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard !pcm.isEmpty else { completion(.failure(ASRError.noTranscript)); return nil }
        var request = makeRequest("\(base)/upload", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAVEncoder.wav(fromPCM: pcm)
        return send(request, completion: completion) { [weak self] json in
            guard let self = self, let url = json["upload_url"] as? String else {
                completion(.failure(ASRError.invalidResponse)); return
            }
            self.submit(audioURL: url, completion: completion)
        }
    }

    private func submit(audioURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        // 3.7 keeps fillers ("um", "嗯") by default; dictation wants them gone.
        var body: [String: Any] = ["audio_url": audioURL, "speech_models": ["assemblyai-stt-3-7", "universal-2"],
                                   "disfluencies": false]
        let languages = hints.assemblyAILanguages
        if languages.count > 1 {
            body["language_codes"] = languages       // code switching, e.g. zh + en
        } else if let code = languages.first {
            body["language_code"] = code
        }
        let terms = hints.hotwords.sorted { $0.value > $1.value }.map(\.key).prefix(Self.maxKeyterms)
        if !terms.isEmpty { body["keyterms_prompt"] = Array(terms) }

        var request = makeRequest("\(base)/transcript", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let task = send(request, completion: completion, onJSON: { [weak self] json in
            guard let self = self, let id = json["id"] as? String else {
                completion(.failure(ASRError.invalidResponse)); return
            }
            self.poll(id: id, deadline: Date().addingTimeInterval(Self.timeout), completion: completion)
        }) { track(task) }
    }

    /// Upload, submit, then up to `timeout` of polling.
    override func resultDeadline(audioSeconds: Double) -> TimeInterval {
        Self.timeout + 20 + audioSeconds * 0.3
    }

    private func poll(id: String, deadline: Date, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isFinishedNow else { return }
        guard Date() < deadline else { completion(.failure(ASRError.timeout)); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            guard let self = self, !self.isFinishedNow else { return }
            let request = self.makeRequest("\(self.base)/transcript/\(id)", method: "GET")
            // The job exists by now; retrying would start (and bill) a second one.
            if let task = self.send(request, retryable: false, completion: completion, onJSON: { [weak self] json in
                switch json["status"] as? String {
                case "completed":
                    let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(text.isEmpty ? .failure(ASRError.noTranscript)
                                            : .success(TranscriptJoiner.removingSpacesBetweenCJK(text)))
                case "error":
                    completion(.failure(ASRError.apiError("AssemblyAI: \(json["error"] as? String ?? "unknown")")))
                default:
                    self?.poll(id: id, deadline: deadline, completion: completion)
                }
            }) { self.track(task) }
        }
    }

    private func makeRequest(_ url: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest, retryable: Bool = true, completion: @escaping (Result<String, Error>) -> Void,
                      onJSON: @escaping ([String: Any]) -> Void) -> URLSessionTask? {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if (error as NSError).code != NSURLErrorCancelled {
                    completion(.failure(retryable ? ASRError.from(error) : ASRError.networkError(error.localizedDescription)))
                }
                return
            }
            if let httpError = HTTPResponseCheck.error(for: response, data: data) {
                completion(.failure(httpError)); return
            }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(ASRError.invalidResponse)); return
            }
            onJSON(json)
        }
        task.resume()
        return task
    }
}

/// AssemblyAI Dictation API ($0.62/h): one request returns send-ready text (`llm_response`:
/// fillers gone, punctuation and self-corrections resolved) plus the verbatim transcript
/// (`text`), so ChillTalk skips its own polish for this provider. Clips up to 2 minutes go to
/// the low-latency `/v1/transcribe/live`, longer ones to `/v1/transcribe`.
/// Docs: https://www.assemblyai.com/docs/dictation.md
final class AssemblyAIDictationASR: BufferedASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private static let host = "https://dictation.assemblyai.com"
    /// `/v1/transcribe/live` takes up to 120 s.
    private static let liveLimitSeconds: Double = 115
    /// Up to 100 key terms and 8000 characters in all.
    static let maxKeyterms = 100
    private static let maxKeytermCharacters = 8000

    private let lock = NSLock()
    private var verbatimText: String?
    private var rewriteFailedFlag = false

    /// The words as spoken, for history; the result itself is the cleaned-up text.
    var verbatim: String? {
        lock.lock()
        defer { lock.unlock() }
        return verbatimText
    }

    /// The cleanup failed (it's best effort) and the result is the verbatim transcript.
    var rewriteFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rewriteFailedFlag
    }

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
    }

    /// Opens the connection while the user speaks, so the upload doesn't wait for the handshake.
    override func start() {
        guard let url = URL(string: Self.host) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    /// AssemblyAI suggests a 90 s client timeout; short clips answer in about a second.
    override func resultDeadline(audioSeconds: Double) -> TimeInterval {
        30 + audioSeconds * 0.5
    }

    override func upload(pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard !pcm.isEmpty else { completion(.failure(ASRError.noTranscript)); return nil }
        let seconds = Double(pcm.count) / 32000
        let path = seconds <= Self.liveLimitSeconds ? "/v1/transcribe/live" : "/v1/transcribe"

        // Unknown fields are rejected with 400, so only these three.
        var config: [String: Any] = [:]
        let languages = hints.assemblyAILanguages
        if !languages.isEmpty { config["language_codes"] = languages }
        let context = hints.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { config["stt_prompt"] = context }
        var terms: [String] = []
        var characters = 0
        for term in hints.hotwords.sorted(by: { $0.value > $1.value }).map(\.key) {
            guard terms.count < Self.maxKeyterms, characters + term.count <= Self.maxKeytermCharacters else { break }
            terms.append(term)
            characters += term.count
        }
        if !terms.isEmpty { config["keyterms_prompt"] = terms }
        guard let configJSON = try? JSONSerialization.data(withJSONObject: config) else {
            completion(.failure(ASRError.invalidResponse)); return nil
        }

        // The live endpoint needs `config` before the audio.
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"config\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(configJSON)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(WAVEncoder.wav(fromPCM: pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: Self.host + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(ASRError.from(error)))
                return
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                completion(.failure(Self.error(status: status, json: json)))
                return
            }
            guard let json, let text = json["text"] as? String else {
                completion(.failure(ASRError.invalidResponse))
                return
            }
            // A failed rewrite still answers 200 with the transcript: use that.
            let cleaned = (json["llm_response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == nil, let reason = json["llm_error"] as? String {
                print("⚠️ AssemblyAI Dictation rewrite failed (\(reason)), using the transcript")
            }
            let verbatim = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (cleaned?.isEmpty == false ? cleaned! : verbatim)
            if let self {
                self.lock.lock()
                self.verbatimText = verbatim
                self.rewriteFailedFlag = cleaned?.isEmpty != false
                self.lock.unlock()
            }
            completion(result.isEmpty ? .failure(ASRError.noTranscript)
                                      : .success(TranscriptJoiner.removingSpacesBetweenCJK(result)))
        }
        task.resume()
        return task
    }

    /// Errors come as `{"status", "title", "detail"}` or `{"error", "error_code"}`.
    private static func error(status: Int, json: [String: Any]?) -> ASRError {
        if status == 401 || status == 403 { return .invalidAPIKey }
        let message = json?["detail"] as? String ?? json?["error"] as? String ?? json?["title"] as? String
        return .apiError("AssemblyAI Dictation HTTP \(status)\(message.map { ": \($0)" } ?? "")")
    }
}
