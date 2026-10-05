import Foundation

/// AssemblyAI Universal-Streaming (v3) real-time transcription.
///
/// Protocol: connect with the API key in the `Authorization` header and settings in the
/// query → `Begin` → binary PCM in 50–1000 ms chunks → `{"type":"Terminate"}` → `Turn`
/// messages (one per utterance, refined until `end_of_turn`) → `Termination`.
/// Docs: https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api
final class AssemblyAIASR: WebSocketASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private let endpoint = "wss://streaming.assemblyai.com/v3/ws"
    private let model = "universal-3-6-pro"

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
        // Cantonese has no separate code here; Chinese covers it.
        var languages: [String] = []
        for code in hints.languageCodes.map({ $0 == "yue" ? "zh" : $0 }) where !languages.contains(code) {
            languages.append(code)
        }
        if let json = Self.jsonArray(languages) {
            items.append(URLQueryItem(name: "language_codes", value: json))
        }
        let terms = hints.hotwords.sorted { $0.value > $1.value }.map(\.key).prefix(Self.maxKeyterms)
        if !terms.isEmpty, let json = Self.jsonArray(Array(terms)) {
            items.append(URLQueryItem(name: "keyterms_prompt", value: json))
        }
        components.queryItems = items
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

/// AssemblyAI pre-recorded transcription ("说完再识别"): upload → submit → poll.
/// Universal-3.5 Pro costs less than real-time and sees the whole recording.
final class AssemblyAIBatchASR: BufferedASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private let base = "https://api.assemblyai.com/v2"
    /// Pre-recorded Universal-3.5 Pro accepts up to 1000 key terms.
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
        var body: [String: Any] = ["audio_url": audioURL, "speech_models": ["universal-3-5-pro", "universal-2"]]
        var languages: [String] = []
        for code in hints.languageCodes.map({ $0 == "yue" ? "zh" : $0 }) where !languages.contains(code) {
            languages.append(code)
        }
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

    private func poll(id: String, deadline: Date, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isCancelledNow else { return }
        guard Date() < deadline else { completion(.failure(ASRError.timeout)); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            guard let self = self, !self.isCancelledNow else { return }
            let request = self.makeRequest("\(self.base)/transcript/\(id)", method: "GET")
            if let task = self.send(request, completion: completion, onJSON: { [weak self] json in
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
    private func send(_ request: URLRequest, completion: @escaping (Result<String, Error>) -> Void,
                      onJSON: @escaping ([String: Any]) -> Void) -> URLSessionTask? {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if (error as NSError).code != NSURLErrorCancelled {
                    completion(.failure(ASRError.networkError(error.localizedDescription)))
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
