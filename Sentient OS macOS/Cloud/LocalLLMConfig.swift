//
//  LocalLLMConfig.swift
//  Sentient OS macOS
//
//  User-configured local LLM endpoint (OpenAI-compatible): baseURL + optional apiKey + model.
//  Stored in UserDefaults. `isConfigured` replaces the old `CodexAuth.knowledgeBaseOnly` gate
//  (inverted polarity: KB-only meant "cloud off", isConfigured means "LLM on").
//

import Foundation

struct LocalLLMConfig: Sendable, Equatable {
    let baseURL: String
    let apiKey: String
    let model: String

    /// Enough to attempt a call. API key is optional (most local servers don't require one).
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let baseURLKey = "localllm.baseURL"
    static let apiKeyKey  = "localllm.apiKey"
    static let modelKey   = "localllm.model"

    /// Ollama's default OpenAI-compatible endpoint. Sane out-of-the-box default; user overrides
    /// for LM Studio (http://localhost:1234/v1), llama.cpp server, vLLM, MLX server, etc.
    static let defaultBaseURL = "http://localhost:11434/v1"
    static let defaultModel   = "llama3.2"

    static func current() -> LocalLLMConfig {
        let d = UserDefaults.standard
        return LocalLLMConfig(
            baseURL: d.string(forKey: baseURLKey) ?? defaultBaseURL,
            apiKey:  d.string(forKey: apiKeyKey)  ?? "",
            model:   d.string(forKey: modelKey)   ?? defaultModel
        )
    }

    static func save(baseURL: String, apiKey: String, model: String) {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: baseURLKey)
        d.set(apiKey,  forKey: apiKeyKey)
        d.set(model,   forKey: modelKey)
    }

    /// App-wide gate (replaces `CodexAuth.knowledgeBaseOnly`). True when an endpoint is set.
    static var isConfigured: Bool { current().isConfigured }
}
