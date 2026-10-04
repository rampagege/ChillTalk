import Foundation

/// Deepgram Nova-3 live streaming transcription.
///
/// Audio streams while the user speaks. On finish we send `CloseStream`; Deepgram flushes the
/// remaining finalized results, sends a `Metadata` message and closes the socket.
final class DeepgramASR: WebSocketASRSession {
    private let apiKey: String
    private let endpoint = "wss://api.deepgram.com/v1/listen"
    private let hints: RecognitionHints
    private var finalSegments: [String] = []
    /// Latest not-yet-final hypothesis for the current span of audio.
    private var interimSegment = ""

    init(apiKey: String, hints: RecognitionHints = .none) {
        self.apiKey = apiKey
        self.hints = hints
        super.init()
    }

    override func makeRequest() -> URLRequest? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: deepgramLanguage),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// Nova-3's `multi` covers English + Japanese (among others) but not Chinese or Korean,
    /// which need their own code.
    private var deepgramLanguage: String {
        if hints.mixEnglish && hints.language == .ja { return "multi" }
        return hints.language.deepgramCode
    }

    override func sendAudio(_ pcm: Data) {
        send(data: pcm)
    }

    override func sendFinish() {
        send(text: #"{"type":"CloseStream"}"#)
    }

    override func currentTranscript() -> String {
        TranscriptJoiner.join(finalSegments + [interimSegment])
    }

    override func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "Results":
            // Final results each cover a different span of audio and must be accumulated;
            // interim results replace each other until that span is finalized.
            guard let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let raw = alternatives.first?["transcript"] as? String else { return }
            let transcript = TranscriptJoiner.removingSpacesBetweenCJK(raw)
            if json["is_final"] as? Bool ?? false {
                if !transcript.isEmpty { finalSegments.append(transcript) }
                interimSegment = ""
            } else {
                interimSegment = transcript
            }
            publishPartial()

        case "Metadata":
            // Sent after CloseStream once all results are flushed.
            if finishRequested { complete() }

        default:
            break
        }
    }
}
