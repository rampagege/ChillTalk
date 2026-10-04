import Foundation

/// Transcription through an OpenAI-compatible `/audio/transcriptions` endpoint.
/// These APIs are upload-only, so audio is buffered and sent when recording stops.
final class OpenAICompatibleASR: BufferedASRSession {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let language: String?
    private let extraHeaders: [String: String]

    init(endpoint: URL, apiKey: String, model: String, language: String?, extraHeaders: [String: String] = [:]) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.extraHeaders = extraHeaders
    }

    /// `language` nil lets Whisper auto-detect (needed for mixed-language speech).
    static func openAIWhisper(apiKey: String, language: String?) -> OpenAICompatibleASR {
        OpenAICompatibleASR(
            endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            apiKey: apiKey,
            model: "whisper-1",
            language: language
        )
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
        if let language = language { appendField("language", language) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

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
