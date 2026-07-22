//
//  LocalLLM.swift
//  Sentient OS macOS
//
//  Minimal OpenAI-compatible chat-completions client over URLSession. No deps, no streaming.
//  Two methods: `run(prompt:)` for text-in/text-out (the proactive judge path), `runAgent(prompt:)`
//  as the phase-2 stub for the agentic paths (vault, connectors, computer use) — throws until the
//  Swift agent loop lands. Mirrors the call shape of the old CodexCLI so the refactor is mostly a
//  1:1 swap.
//
//  Config lives in LocalLLMConfig (UserDefaults). `endpointConfigured` is the app-wide gate that
//  replaced CodexAuth.knowledgeBaseOnly.
//

import Foundation
import os

actor LocalLLM {

    static let shared = LocalLLM()

    enum LLMError: Error, CustomStringConvertible {
        case notConfigured
        case badEndpoint(String)
        case http(status: Int, body: String)
        case network(String)
        case agentLoopDisabled          // ponytail: phase-2 stub — vault/connectors/computer use wait on the agent loop

        var description: String {
            switch self {
            case .notConfigured:        return "No local LLM endpoint configured. Set one in Settings → Permissions & Health."
            case .badEndpoint(let m):   return "Local LLM endpoint error: \(m)"
            case .http(let s, let b):   return "Local LLM HTTP \(s): \(b.prefix(200))"
            case .network(let m):       return "Local LLM network error: \(m)"
            case .agentLoopDisabled:    return "This feature needs the local-LLM agent loop (coming in phase 2)."
            }
        }
    }

    /// Cached snapshot of the config so the same call doesn't re-read UserDefaults every time.
    /// Invalidated by `reloadConfig()` (called by Settings when the user saves).
    private var cached: LocalLLMConfig?

    /// Config snapshot — internal so the agent-loop extension (LocalLLMAgent.swift) can reach it.
    func config() throws -> LocalLLMConfig {
        if let cached { return cached }
        let c = LocalLLMConfig.current()
        guard c.isConfigured else { throw LLMError.notConfigured }
        cached = c
        return c
    }

    /// Force a re-read on next call. Settings calls this after a save.
    func reloadConfig() { cached = nil }

    /// One-shot chat completion. Returns the assistant message content.
    /// `system` is optional system-prompt; `onLine` is invoked once with the full content (no
    /// streaming — most local servers are fast enough for a single shot, and SSE parsing is its
    /// own project; the agent loop in phase 2 will add streaming).
    func run(prompt: String, system: String? = nil, timeout: TimeInterval = 600,
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let cfg = try config()
        let trimmed = cfg.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/chat/completions") else {
            throw LLMError.badEndpoint("invalid baseURL: \(cfg.baseURL)")
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: String]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])

        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": cfg.model,
            "messages": messages,
            "stream": false,
            // ponytail: matches the on-device Engine's triage temp — local models like a low temp
            // for stable JSON verdicts; bump for creative paths later if needed.
            "temperature": 0.15,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.network("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badEndpoint("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(status: http.statusCode, body: body)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.badEndpoint("no choices[0].message.content in response")
        }
        onLine?(content)
        return content
    }

    /// Phase-2 stub for the agentic paths (vault create/update, connectors, computer use). Throws
    /// until a Swift agent loop with file/shell/MCP tools is built on top of OpenAI tool-calling.
    func runAgent(_ prompt: String, timeout: TimeInterval = 1_800,
                  onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        throw LLMError.agentLoopDisabled
    }

    /// Quick connectivity probe. nil on success, error text on failure. Used by Settings → Test.
    func ping() async -> String? {
        guard LocalLLMConfig.current().isConfigured else { return "Not configured" }
        do {
            _ = try await run(prompt: "Reply with exactly: PONG", timeout: 15)
            return nil
        } catch {
            return "\(error)"
        }
    }
}
