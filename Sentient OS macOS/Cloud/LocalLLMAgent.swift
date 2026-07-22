//
//  LocalLLMAgent.swift
//  Sentient OS macOS
//
//  Generic OpenAI tool-calling agent loop on top of the LocalLLM client. Sends `system + user
//  (+ optional images)` then loops: tool_call → execute → tool_result → next response, until the
//  model emits a final assistant message with no tool call (or maxTurns is hit, or the user
//  cancels).
//
//  Multimodal: image data is base64'd and sent as image_url content blocks in the user message
//  (OpenAI-compatible; works with Ollama, llama.cpp server, LM Studio, vLLM, MLX server). For
//  text-only models, omit images.
//
//  Lenient parsing: many local models mangle `tool_calls` (extra prose, JSON-as-string, wrong
//  shape). We recover gracefully — extract a function call from almost any plausible shape and
//  fall back to "no tool call, return content" when nothing parses.
//
//  The tool set is supplied by the caller (AgentTool with an `execute` closure), so the same loop
//  drives computer use (Cloud/ComputerUse.swift), the phase-2 file/MCP agent loop, and any future
//  agentic feature. No hard-coded tool surface.
//

import Foundation
import os

/// One tool the agent can call. Sendable; `execute` runs in the loop's task tree.
struct AgentTool: Sendable {
    let name: String
    let description: String
    /// JSON Schema for the tool's parameters (OpenAI tools format). Built once at construction.
    let parameters: [String: Any]
    /// Run the tool. Returns the text result fed back to the model as a `tool` message.
    /// Throw `TerminalSignal` to end the loop (done/could_not); any other error becomes the tool
    /// result message so the model can recover.
    let execute: @Sendable ([String: Any]) async throws -> String

    /// JSON-schema fragment as the OpenAI tools format wants it (already a dict).
    var openAITool: [String: Any] {
        ["type": "function",
         "function": [
            "name": name,
            "description": description,
            "parameters": parameters,
         ]]
    }
}

/// Thrown by a tool to end the loop with a verdict. `done(summary)` and `could_not(reason)` map
/// to this; the caller treats the signal as the run's outcome.
struct TerminalSignal: Error, Sendable {
    enum Outcome: Sendable { case done, couldNot }
    let outcome: Outcome
    let message: String
}

/// One assistant turn — what the model said, plus an optional tool call to execute.
struct AgentTurn: Sendable {
    let narration: String?               // the assistant's text content (model often explains)
    let toolCall: (id: String, name: String, arguments: [String: Any])?
}

extension LocalLLM {

    /// Run the agent loop. Returns the assistant's final message text (or, on maxTurns, its last
    /// narration). Throws on endpoint errors / notConfigured / cancellation.
    ///
    /// - Parameter onTurn: fires for every assistant turn with the parsed narration + tool call —
    ///   the caller surfaces play-by-play ("Clicking the login button") as it streams.
    /// - Parameter screenshotProvider: when set, the loop captures a fresh screenshot after EACH
    ///   tool call and appends a new user message carrying the image(s). Drives computer use: the
    ///   model sees fresh state after every action without needing to call `screenshot` explicitly.
    func runAgentLoop(
        system: String,
        user: String,
        images: [Data] = [],
        tools: [AgentTool],
        maxTurns: Int = 20,
        timeout: TimeInterval = 1_800,
        screenshotProvider: (@Sendable () async -> [Data])? = nil,
        onTurn: (@Sendable (AgentTurn) -> Void)? = nil
    ) async throws -> String {

        // Build the initial message list. System + user (with optional image content blocks).
        var messages: [[String: Any]] = []
        messages.append(["role": "system", "content": system])

        // ponytail: image content blocks for the FIRST user message only. Loop iterations add
        // fresh screenshots after each tool call via `screenshotProvider`.
        if images.isEmpty {
            messages.append(["role": "user", "content": user])
        } else {
            var content: [[String: Any]] = [["type": "text", "text": user]]
            for img in images {
                let b64 = img.base64EncodedString()
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(b64)"],
                ])
            }
            messages.append(["role": "user", "content": content])
        }

        // Tool lookup so the executor can find the closure by name.
        let toolMap: [String: AgentTool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        for turn in 1...maxTurns {
            try Task.checkCancellation()   // the user's STOP

            // Call chat/completions with the current messages + tool definitions.
            let raw = try await chatComplete(
                messages: messages,
                tools: tools.map(\.openAITool),
                timeout: timeout
            )

            // Parse the response into narration + (optional) tool call. Lenient — local models
            // vary widely in tool_call shape compliance.
            let parsed = try Self.parseAssistantTurn(raw)
            onTurn?(AgentTurn(narration: parsed.narration, toolCall: parsed.toolCall))

            // Append the assistant message back into the running history (verbatim as we received
            // it — including the tool_calls array if present — so the next call's `tool` result
            // can reference the same tool_call_id).
            messages.append(parsed.rawMessage)

            // No tool call → this is the final answer.
            guard let call = parsed.toolCall else {
                return parsed.narration ?? "(no output)"
            }

            // Execute the tool. Unknown tool name → "unknown tool" result fed back to the model.
            // `done` / `could_not` surface as thrown ComputerUseError and bubble out of the loop.
            var resultText: String
            if let tool = toolMap[call.name] {
                do {
                    resultText = try await tool.execute(call.arguments)
                } catch let terminalError as TerminalSignal {
                    throw terminalError   // done/could_not → escape the loop, caller handles
                } catch {
                    resultText = "ERROR: \(error)"
                }
            } else {
                resultText = "ERROR: unknown tool '\(call.name)'"
            }

            // Build the tool result message. If we have a screenshot provider, capture fresh
            // images and attach them to a user message BEFORE the tool result so the model sees
            // what its action did. (Order matters: tool result, then fresh-state image, then the
            // next turn the model reasons over both.)
            messages.append([
                "role": "tool",
                "tool_call_id": call.id,
                "content": resultText,
            ])

            if let screenshotProvider {
                let fresh = await screenshotProvider()
                if !fresh.isEmpty {
                    var content: [[String: Any]] = [
                        ["type": "text", "text": "The screen after your action:"],
                    ]
                    for img in fresh {
                        let b64 = img.base64EncodedString()
                        content.append([
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(b64)"],
                        ])
                    }
                    messages.append(["role": "user", "content": content])
                }
            }
        }

        // Hit maxTurns — return the last narration as a graceful stop.
        return "(max turns reached)"
    }

    // MARK: - Chat completion with tools + multimodal

    /// Full-fat chat/completions call. Builds the request body, posts to /chat/completions, returns
    /// the raw assistant message DICT (content + tool_calls). Throws LLMError on any failure.
    func chatComplete(messages: [[String: Any]], tools: [[String: Any]] = [],
                      timeout: TimeInterval = 600) async throws -> [String: Any] {
        let cfg = try await config()
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

        var body: [String: Any] = [
            "model": cfg.model,
            "messages": messages,
            "stream": false,
            "temperature": 0.15,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
              let message = first["message"] as? [String: Any] else {
            throw LLMError.badEndpoint("no choices[0].message in response")
        }
        return message
    }

    // MARK: - Lenient turn parsing

    /// The parsed assistant turn plus the verbatim dict we'll append back to the running history
    /// (so the tool result can reference the same tool_call_id).
    struct ParsedTurn {
        let narration: String?
        let toolCall: (id: String, name: String, arguments: [String: Any])?
        let rawMessage: [String: Any]
    }

    /// Extract narration + tool call from the assistant message dict. Tolerates:
    ///  - standard OpenAI tool_calls array
    ///  - function_call legacy shape
    ///  - tool call smuggled inside the content string as ```json {...}```
    ///  - no tool call at all (final answer)
    static func parseAssistantTurn(_ message: [String: Any]) -> ParsedTurn {
        let narration = message["content"] as? String

        // Standard OpenAI shape: tool_calls: [{id, function: {name, arguments}}]
        if let calls = message["tool_calls"] as? [[String: Any]],
           let first = calls.first,
           let id = first["id"] as? String,
           let fn = first["function"] as? [String: Any],
           let name = fn["name"] as? String {
            let args = parseArguments(fn["arguments"])
            return ParsedTurn(
                narration: narration,
                toolCall: (id: id, name: name, arguments: args),
                rawMessage: message
            )
        }

        // Legacy function_call shape (older OpenAI-compatible servers).
        if let fn = message["function_call"] as? [String: Any],
           let name = fn["name"] as? String {
            let id = (fn["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
            let args = parseArguments(fn["arguments"])
            // Normalize to the modern shape in the raw we append back.
            var normalized = message
            normalized["tool_calls"] = [[
                "id": id,
                "type": "function",
                "function": ["name": name, "arguments": argsJSONString(args)],
            ]]
            return ParsedTurn(
                narration: narration,
                toolCall: (id: id, name: name, arguments: args),
                rawMessage: normalized
            )
        }

        // Last-ditch: scan the content for a ```json { ... }``` block that looks like a tool call.
        // ponytail: covers models that emit tool calls as text rather than via the API shape.
        if let narration,
           let smuggled = Self.smuggleToolCall(from: narration) {
            let id = "call_\(UUID().uuidString.prefix(8))"
            var normalized = message
            normalized["tool_calls"] = [[
                "id": id,
                "type": "function",
                "function": ["name": smuggled.name, "arguments": argsJSONString(smuggled.arguments)],
            ]]
            return ParsedTurn(
                narration: narration,
                toolCall: (id: id, name: smuggled.name, arguments: smuggled.arguments),
                rawMessage: normalized
            )
        }

        return ParsedTurn(narration: narration, toolCall: nil, rawMessage: message)
    }

    /// `arguments` can arrive as a JSON string OR a dict; handle both.
    private static func parseArguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        if let s = raw as? String,
           let data = s.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }

    /// Re-serialize a dict as a JSON string (the form OpenAI's tools API wants in arguments).
    private static func argsJSONString(_ args: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
    }

    /// Look for a fenced or bare JSON object in `text` with a `name` field that matches a known
    /// tool name. Returns the (name, arguments) pair, or nil. ponytail: lenient fallback — only
    /// triggers when the API shape didn't surface a tool call.
    static func smuggleToolCall(from text: String) -> (name: String, arguments: [String: Any])? {
        // Find the widest {…} span.
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let span = String(text[start...end])
        guard let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        let args = (obj["arguments"] as? [String: Any])
            ?? (obj["parameters"] as? [String: Any])
            ?? (obj["args"] as? [String: Any])
            ?? obj.compactMapValues { $0 }
        return (name, args)
    }
}
