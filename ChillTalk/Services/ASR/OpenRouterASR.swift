import Foundation

extension OpenAICompatibleASR {
    /// Experimental: Whisper through OpenRouter's OpenAI-compatible transcription endpoint.
    static func openRouter(apiKey: String, language: String?) -> OpenAICompatibleASR {
        OpenAICompatibleASR(
            endpoint: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!,
            apiKey: apiKey,
            model: "openai/whisper-large-v3",
            language: language,
            extraHeaders: [
                "HTTP-Referer": "ChillTalk/1.0",
                "X-Title": "ChillTalk"
            ]
        )
    }
}
