import Foundation

/// Alibaba Cloud Model Studio (DashScope) realtime recognition over WebSocket
/// (Qwen-Audio-ASR streaming / Fun-ASR realtime share this protocol).
///
/// Protocol: connect → `run-task` → wait for `task-started` → stream binary PCM →
/// `finish-task` → `result-generated`… → `task-finished`.
/// Docs: https://www.alibabacloud.com/help/en/model-studio/fun-asr-realtime-websocket-api
final class DashScopeASR: WebSocketASRSession {
    private let apiKey: String
    private let endpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    private let model: String
    private let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private var taskStarted = false
    /// Audio captured before `task-started`; the server rejects audio sent earlier.
    private var pendingAudio: [Data] = []
    private var finishPending = false
    private var finalSentences: [String] = []
    private var partialSentence = ""

    /// Hot words and context text from the user's vocabulary.
    private let hints: RecognitionHints
    /// DashScope limit for context text per turn.
    static let maxContextLength = 400

    init(apiKey: String, model: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.model = model
        self.hints = hints
        super.init()
    }

    override func makeRequest() -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    override func socketDidOpen() {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000
        ]
        if !hints.hotwords.isEmpty {
            parameters["vocabulary"] = hints.hotwords
        }
        parameters["language_hints"] = hints.languageCodes
        var input: [String: Any] = [:]
        let context = hints.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            input["context"] = [[
                "role": "user",
                "content": [["type": "input_text", "text": String(context.prefix(Self.maxContextLength))]]
            ]]
        }
        let runTask: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": input
            ]
        ]
        sendJSON(runTask)
    }

    override func sendAudio(_ pcm: Data) {
        if taskStarted {
            send(data: pcm)
        } else {
            pendingAudio.append(pcm)
        }
    }

    override func sendFinish() {
        if taskStarted {
            sendFinishTask()
        } else {
            finishPending = true
        }
    }

    override func currentTranscript() -> String {
        TranscriptJoiner.join(finalSentences + [partialSentence])
    }

    override func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            return
        }

        switch event {
        case "task-started":
            taskStarted = true
            signalReady()
            pendingAudio.forEach { send(data: $0) }
            pendingAudio.removeAll()
            if finishPending { sendFinishTask() }

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }
            if sentence["heartbeat"] as? Bool == true { return }
            let text = sentence["text"] as? String ?? ""
            if sentence["sentence_end"] as? Bool == true {
                finalSentences.append(text)
                partialSentence = ""
            } else {
                partialSentence = text
            }
            publishPartial()

        case "task-finished":
            complete()

        case "task-failed":
            let code = header["error_code"] as? String ?? "UNKNOWN"
            let message = header["error_message"] as? String ?? String(localized: "未知错误")
            if code.localizedCaseInsensitiveContains("auth") || code == "InvalidApiKey" {
                fail(ASRError.invalidAPIKey)
            } else {
                fail(ASRError.apiError("DashScope \(code): \(message)"))
            }

        default:
            break
        }
    }

    private func sendFinishTask() {
        finishPending = false
        sendJSON([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [String: Any]()]
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        send(text: string)
    }
}

/// Qwen-ASR on the whole recording ("说完再识别"): one OpenAI-compatible request with the
/// audio inline. Cheaper than streaming and sees the full sentence, at the cost of waiting
/// for the upload and recognition after the user stops.
final class QwenBatchASR: BufferedASRSession {
    private let apiKey: String
    private let hints: RecognitionHints
    private let model = "qwen3-asr-flash"
    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    /// The API accepts at most 5 minutes (10 MB) per request.
    static let maxSeconds: Double = 290

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
    }

    override func upload(pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard !pcm.isEmpty else { completion(.failure(ASRError.noTranscript)); return nil }
        guard Double(pcm.count) / 32000 <= Self.maxSeconds else {
            completion(.failure(ASRError.apiError(String(localized: "录音超过 5 分钟，请改用实时识别"))))
            return nil
        }

        var messages: [[String: Any]] = []
        // Context biasing: the background description plus vocabulary terms.
        let terms = hints.hotwords.sorted { $0.value > $1.value }.map(\.key).prefix(200)
        let context = ([hints.context] + (terms.isEmpty ? [] : [terms.joined(separator: "、")]))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !context.isEmpty {
            messages.append(["role": "system", "content": [["type": "text", "text": context]]])
        }
        let audio = "data:audio/wav;base64," + WAVEncoder.wav(fromPCM: pcm).base64EncodedString()
        messages.append(["role": "user", "content": [["type": "input_audio", "input_audio": ["data": audio]]]])

        var asrOptions: [String: Any] = ["enable_itn": true]
        if let language = hints.singleLanguage { asrOptions["language"] = language }
        let body: [String: Any] = ["model": model, "messages": messages, "stream": false, "asr_options": asrOptions]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(ASRError.networkError(error.localizedDescription)))
                return
            }
            if let httpError = HTTPResponseCheck.error(for: response, data: data) {
                completion(.failure(httpError))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                completion(.failure(ASRError.invalidResponse))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed.isEmpty ? .failure(ASRError.noTranscript) : .success(trimmed))
        }
        task.resume()
        return task
    }
}
