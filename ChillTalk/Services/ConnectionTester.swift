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
            // Recognize half a second of silence: checks the key and the chosen model.
            let session = provider.makeSession(apiKey: key, mode: .batch)
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
        case .openAIWhisper:
            return await testHTTP(url: "https://api.openai.com/v1/models", apiKey: key)
        case .openRouter:
            return await testHTTP(url: "https://openrouter.ai/api/v1/key", apiKey: key)
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

    private static func testHTTP(url: String, apiKey: String) async -> ConnectionTestResult {
        guard let url = URL(string: url) else { return .failure(String(localized: "无效的服务地址")) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        return await measure { finish in
            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        finish(.failure(error.localizedDescription))
                    } else if let httpError = HTTPResponseCheck.error(for: response, data: data) {
                        finish(.failure(httpError.localizedDescription))
                    } else {
                        finish(.success(latencyMs: 0))
                    }
                }
            }.resume()
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
