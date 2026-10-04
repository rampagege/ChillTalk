import Foundation

/// Soniox real-time transcription over WebSocket.
///
/// Protocol: connect → JSON config (includes the API key) → binary PCM → empty frame to end
/// → token messages → `{"finished": true}`. Final tokens arrive once and accumulate;
/// non-final tokens are the current tail and are replaced by each message.
/// Docs: https://soniox.com/docs/stt/api-reference/websocket-api
final class SonioxASR: WebSocketASRSession {
    private let apiKey: String
    private let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket"
    private let model = "stt-rt-v5"
    private let hints: RecognitionHints

    private var finalText = ""
    private var tailText = ""

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
        super.init()
    }

    override func makeRequest() -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        return request
    }

    /// The config must be the first message, ahead of any audio, so it's queued as soon as
    /// the socket exists rather than when it opens.
    override func socketCreated() {
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "language_hints": hints.languageCodes
        ]
        var context: [String: Any] = [:]
        if !hints.hotwords.isEmpty {
            // Soniox takes plain terms; list the super hot words first.
            context["terms"] = hints.hotwords.sorted { $0.value > $1.value }.map(\.key)
        }
        let contextText = hints.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contextText.isEmpty {
            context["text"] = contextText
        }
        if !context.isEmpty {
            config["context"] = context
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text: text)
    }

    /// Soniox says nothing until audio arrives, so an open socket is as ready as it gets.
    override func socketDidOpen() {
        signalReady()
    }

    override func sendAudio(_ pcm: Data) {
        send(data: pcm)
    }

    override func sendFinish() {
        send(data: Data())
    }

    override func currentTranscript() -> String {
        (finalText + tailText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let code = json["error_code"] {
            let message = json["error_message"] as? String ?? String(localized: "未知错误")
            if "\(code)" == "401" {
                fail(ASRError.invalidAPIKey)
            } else {
                fail(ASRError.apiError("Soniox \(code): \(message)"))
            }
            return
        }

        if let tokens = json["tokens"] as? [[String: Any]] {
            var tail = ""
            for token in tokens {
                guard let piece = token["text"] as? String, !Self.isControlToken(piece) else { continue }
                if token["is_final"] as? Bool == true {
                    finalText += piece
                } else {
                    tail += piece
                }
            }
            tailText = tail
            publishPartial()
        }

        if json["finished"] as? Bool == true {
            complete()
        }
    }

    /// Markers such as "<end>" (endpoint detection) aren't transcript text.
    private static func isControlToken(_ text: String) -> Bool {
        text.hasPrefix("<") && text.hasSuffix(">")
    }
}
