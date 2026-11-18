import Foundation

enum ConnectionTestResult: Equatable {
    case success(latencyMs: Int)
    case failure(String)
}

/// Checks that a provider + key (+ model) combination works, without recording anything.
@MainActor
enum ConnectionTester {
    static let timeout: TimeInterval = 10

    static func testASR(provider: ASRProviderType, apiKey: String,
                        mode: RecognitionMode = .realtime) async -> ConnectionTestResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(String(localized: "请先填写 API 密钥")) }

        if provider == .dashScope && provider.effectiveMode(mode) == .batch {
            return await testWithSilence(provider: provider, apiKey: key)
        }

        switch provider {
        case .dashScope, .deepgram, .assemblyAI:
            // Open a real session and stop as soon as the provider says it's ready.
            // DashScope only reports ready after accepting run-task, which also validates the model.
            guard let session = provider.makeSession(apiKey: key) as? WebSocketASRSession else {
                return .failure(String(localized: "不支持测试此服务"))
            }
            return await measure { finish in
                session.onReady = { finish(.success(latencyMs: 0)) }
                session.onError = { finish(.failure($0.localizedDescription)) }
                session.start()
            } cleanup: {
                session.cancel()
            }
        case .openAIWhisper, .openRouter, .assemblyAIDictation:
            return await testWithSilence(provider: provider, apiKey: key)
        case .soniox:
            // Soniox only checks the key once the stream is used, so open it and end it at
            // once: "finished" means the key worked, an error message means it didn't.
            let session = provider.makeSession(apiKey: key)
            return await measure { finish in
                session.onError = { finish(.failure($0.localizedDescription)) }
                session.start()
                session.finish { result in
                    switch result {
                    case .success:
                        finish(.success(latencyMs: 0))
                    case .failure(let error):
                        if case ASRError.noTranscript = error {
                            finish(.success(latencyMs: 0))
                        } else {
                            finish(.failure(error.localizedDescription))
                        }
                    }
                }
            } cleanup: {
                session.cancel()
            }
        }
    }

    static func testPolish(provider: PolishProvider, apiKey: String, model: String) async -> ConnectionTestResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(String(localized: "请先填写 API 密钥")) }
        let polish = LLMPolish(provider: provider, apiKey: key, model: model)
        return await measure { finish in
            polish.polish(text: String(localized: "测试一下连接")) { result in
                switch result {
                case .success: finish(.success(latencyMs: 0))
                case .failure(let error): finish(.failure(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Private

    /// Recognizes half a second of silence with an upload-only session: checks the key, the
    /// model and the request fields the real dictation sends.
    private static func testWithSilence(provider: ASRProviderType, apiKey: String) async -> ConnectionTestResult {
        let session = provider.makeSession(apiKey: apiKey, mode: .batch)
        return await measure { finish in
            session.onError = { finish(.failure($0.localizedDescription)) }
            session.start()
            session.append(Data(count: 16000))
            session.finish { result in
                switch result {
                case .success:
                    finish(.success(latencyMs: 0))
                case .failure(let error):
                    if case ASRError.noTranscript = error {
                        finish(.success(latencyMs: 0))
                    } else {
                        finish(.failure(error.localizedDescription))
                    }
                }
            }
        } cleanup: {
            session.cancel()
        }
    }

    /// Runs `start`, waits for its first `finish` call or the timeout, and fills in latency.
    private static func measure(
        _ start: (@escaping (ConnectionTestResult) -> Void) -> Void,
        cleanup: @escaping () -> Void = {}
    ) async -> ConnectionTestResult {
        let began = Date()
        let result: ConnectionTestResult = await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (ConnectionTestResult) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(String(localized: "连接超时（\(Int(timeout)) 秒）")))
            }
        }
        cleanup()
        if case .success = result {
            return .success(latencyMs: Int(Date().timeIntervalSince(began) * 1000))
        }
        return result
    }
}
