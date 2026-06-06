import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol PromptOptimizing: Sendable {
    func optimizePrompt(_ text: String, projectFiles: [String]) async -> PromptOptimizationResult
}

struct PromptOptimizationProvider: Identifiable, Hashable {
    var id: String
    var displayName: String
    var baseURL: String
    var defaultModel: String

    static let all: [PromptOptimizationProvider] = [
        PromptOptimizationProvider(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-v4-flash"
        ),
        PromptOptimizationProvider(
            id: "moonshot",
            displayName: "Moonshot Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2"
        ),
        PromptOptimizationProvider(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-5.4-mini"
        ),
        PromptOptimizationProvider(
            id: "custom",
            displayName: "自定义",
            baseURL: "",
            defaultModel: ""
        )
    ]

    static var defaultProvider: PromptOptimizationProvider { all[0] }

    static func resolve(_ id: String) -> PromptOptimizationProvider {
        all.first { $0.id == id } ?? defaultProvider
    }
}

struct PromptOptimizationSettings: Equatable, Sendable {
    static let providerKey = "promptOptimization.provider"
    static let baseURLKey = "promptOptimization.baseURL"
    static let modelKey = "promptOptimization.model"
    static let apiKeyKey = "promptOptimization.apiKey"

    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String

    static func current(defaults: UserDefaults = .standard) -> PromptOptimizationSettings {
        let modeID = defaults.string(forKey: PromptOptimizationMode.storageKey) ?? PromptOptimizationMode.defaultID
        let mode = PromptOptimizationMode.resolve(modeID)
        let providerID = mode == .useDefault
            ? PromptOptimizationProvider.defaultProvider.id
            : (defaults.string(forKey: providerKey) ?? PromptOptimizationProvider.defaultProvider.id)
        let provider = PromptOptimizationProvider.resolve(providerID)
        let baseURL = mode == .useDefault
            ? provider.baseURL
            : (defaults.string(forKey: baseURLKey) ?? provider.baseURL)
        let model = mode == .useDefault
            ? provider.defaultModel
            : (defaults.string(forKey: modelKey) ?? provider.defaultModel)
        return PromptOptimizationSettings(
            providerID: providerID,
            baseURL: baseURL,
            model: model,
            apiKey: defaults.string(forKey: apiKeyKey) ?? ""
        )
    }

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var missingConfigurationMessage: String? {
        if normalizedBaseURL.isEmpty { return "请在 Settings 配置 Prompt 优化服务 Base URL" }
        if normalizedModel.isEmpty { return "请在 Settings 配置 Prompt 优化模型" }
        if normalizedAPIKey.isEmpty { return "请在 Settings 配置 Prompt 优化 API Key" }
        return nil
    }
}

public final class PromptOptimizationClient: PromptOptimizing, @unchecked Sendable {
    private let defaults: UserDefaults
    private let session: URLSession

    public init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    public func optimizePrompt(_ text: String, projectFiles: [String]) async -> PromptOptimizationResult {
        let settings = PromptOptimizationSettings.current(defaults: defaults)
        if let message = settings.missingConfigurationMessage {
            return .failure(message)
        }
        guard let url = Self.chatCompletionsURL(baseURL: settings.normalizedBaseURL) else {
            return .failure("Prompt 优化服务 Base URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.normalizedAPIKey)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionRequest(
            model: settings.normalizedModel,
            messages: [
                APIMessage(
                    role: "system",
                    content: "你只负责优化用户给编码 agent 的提示词。只输出改写后的提示词正文。"
                ),
                APIMessage(
                    role: "user",
                    content: PromptOptimizer.metaPrompt(for: text, projectFiles: projectFiles)
                )
            ],
            stream: false
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Prompt 优化服务响应无效")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("HTTP \(http.statusCode): \(body.prefix(300))")
            }
            let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let cleaned = PromptOptimizer.clean(completion.choices.first?.message.content ?? "")
            return cleaned.isEmpty ? .failure("在线 AI 没有返回改写结果") : .success(cleaned)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func chatCompletionsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/chat/completions")
    }

    private struct ChatCompletionRequest: Encodable {
        var model: String
        var messages: [APIMessage]
        var stream: Bool
    }

    private struct APIMessage: Encodable {
        var role: String
        var content: String
    }

    private struct ChatCompletionResponse: Decodable {
        var choices: [Choice]

        struct Choice: Decodable {
            var message: Message
        }

        struct Message: Decodable {
            var content: String
        }
    }
}
