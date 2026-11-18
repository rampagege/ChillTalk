import Foundation

extension OpenAICompatibleASR {
    /// Experimental: Qwen3-ASR through OpenRouter's OpenAI-compatible transcription endpoint.
    /// About the price of Whisper large-v3 ($0.03/h) and much better at Chinese and its dialects.
    static func openRouter(apiKey: String, language: String?) -> OpenAICompatibleASR {
        OpenAICompatibleASR(
            endpoint: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!,
            apiKey: apiKey,
            model: "qwen/qwen3-asr-1.7b",
            // `language` nil lets the model auto-detect (needed for mixed-language speech).
            fields: language.map { [("language", $0)] } ?? [],
            extraHeaders: [
                "HTTP-Referer": "ChillTalk/1.0",
                "X-Title": "ChillTalk"
            ]
        )
    }
}
