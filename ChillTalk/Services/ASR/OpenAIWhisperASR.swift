import Foundation

/// Transcription through an OpenAI-compatible `/audio/transcriptions` endpoint.
/// These APIs are upload-only, so audio is buffered and sent when recording stops.
final class OpenAICompatibleASR: BufferedASRSession {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    /// Form fields besides `file` and `model`. Arrays repeat the field with a `[]` suffix
    /// (`keywords[]`), the same way OpenAI's own clients send them.
    private let fields: [(name: String, value: String)]
    private let extraHeaders: [String: String]

    init(endpoint: URL, apiKey: String, model: String, fields: [(name: String, value: String)],
         extraHeaders: [String: String] = [:]) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.fields = fields
        self.extraHeaders = extraHeaders
    }

    /// GPT-Transcribe ($0.0045/min): takes the background text as `prompt`, vocabulary terms as
    /// `keywords` and every language the user speaks as `languages`, so mixed speech isn't forced
    /// into one language.
    static func openAI(apiKey: String, hints: RecognitionHints) -> OpenAICompatibleASR {
        var fields: [(name: String, value: String)] = [("response_format", "json")]
        let context = hints.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { fields.append(("prompt", context)) }
        for term in keywords(from: hints.hotwords) { fields.append(("keywords[]", term)) }
        var languages = [hints.language.whisperCode]
        if hints.mixEnglish && hints.language != .en { languages.append("en") }
        for code in languages { fields.append(("languages[]", code)) }
        return OpenAICompatibleASR(
            endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            apiKey: apiKey,
            model: "gpt-transcribe",
            fields: fields
        )
    }

    /// Strongest terms first. Keywords must be single lines without angle brackets.
    static let maxKeywords = 100
    private static func keywords(from hotwords: [String: Int]) -> [String] {
        hotwords.sorted { $0.value > $1.value }
            .map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }) }
            .prefix(maxKeywords)
            .map { $0 }
    }

    override func upload(pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard !pcm.isEmpty else {
            completion(.failure(ASRError.noTranscript))
            return nil
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(WAVEncoder.wav(fromPCM: pcm))
        body.append(Data("\r\n".utf8))
        appendField("model", model)
        for field in fields { appendField(field.name, field.value) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(ASRError.from(error)))
                return
            }
            if let httpError = HTTPResponseCheck.error(for: response, data: data) {
                completion(.failure(httpError))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
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
