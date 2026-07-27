//
//  AgentStatus.swift
//  Sentient OS macOS
//
//  The `STATUS: DONE — …` / `STATUS: COULD_NOT — …` sentinel that every app-authored codex
//  wrapper prompt demands as its final line, parsed leniently from a reply. ONE parser for both
//  consumers — ProactiveExecutor (the card fire channels) and CommandRunModel (Sidekick / the
//  command bar) — so their honesty semantics can never drift.
//
//  ⚠️ Why bottom-up + the both-forms guard: `codex exec`'s human-readable output ECHOES the prompt
//  (a `user` section), and the wrapper's own instruction line contains BOTH sentinel forms — a
//  naive whole-output `contains("STATUS: COULD_NOT")` reads the echo and misreports every run as
//  refused (field-found 2026-07-17; it was live in the executor's computer channel). Scanning
//  lines from the END finds the model's real final line first (codex even repeats the final
//  message at the very end of its output); a line carrying BOTH forms is the echoed instruction
//  itself → no sentinel.
//
//  Key method: AgentStatus.parse(_:) — works on a bare final message (the connector channels'
//  `env.result`) AND on codex's full human-readable output (`runAgentCommand`).
//

import Foundation

nonisolated enum AgentStatus {
    case done                      // STATUS: DONE — the agent claims it completed the task
    case couldNot(reason: String)  // STATUS: COULD_NOT — it cleanly gave up (reason may be empty)
    case none                      // no sentinel in the reply (legacy prompt / the model forgot)

    /// Parse a reply for the sentinel. Bottom-up: the first `STATUS:`-bearing line from the END
    /// decides — the model's final line always sits below any prompt echo.
    static func parse(_ reply: String) -> AgentStatus {
        for line in reply.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let upper = line.uppercased()
            guard upper.contains("STATUS:") else { continue }
            let done = upper.contains("DONE")
            let couldNot = upper.contains("COULD_NOT")
            if done && couldNot { return .none }   // the echoed instruction line ("… OR …") — no real sentinel below it
            if couldNot { return .couldNot(reason: reason(of: String(line))) }
            if done { return .done }
            // A stray "STATUS:" line that is neither form — keep scanning up.
        }
        // Legacy form (pre-sentinel wrappers): a bare final message that OPENS with "COULD NOT".
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("COULD NOT") {
            return .couldNot(reason: String(String(trimmed.dropFirst("COULD NOT".count))
                .trimmingCharacters(in: trimSet).prefix(300)))
        }
        return .none
    }

    /// The display-ready text after the marker on a `STATUS: DONE — <what you did>` line: "" if the
    /// reply has no DONE sentinel (caller falls back to the command). A standalone bottom-up scan so
    /// it can be called independently of `parse(_:)` — the Sidekick history + completion notification
    /// use it to surface what the agent actually did, beyond the bare "✓ done".
    static func summary(of reply: String) -> String {
        for line in reply.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let upper = line.uppercased()
            guard upper.contains("STATUS:") else { continue }
            let done = upper.contains("DONE")
            let couldNot = upper.contains("COULD_NOT")
            if done && couldNot { return "" }   // the echoed instruction line ("… OR …") — no real sentinel
            if done { return excerpt(of: String(line)) }
            // A stray "STATUS:" line that is neither form — keep scanning up.
        }
        return ""
    }

    /// The display-ready text after the marker on a `STATUS: COULD_NOT — <reason>` line.
    private static func reason(of line: String) -> String {
        guard let r = line.range(of: "COULD_NOT", options: [.backwards, .caseInsensitive]) else { return "" }
        return String(String(line[r.upperBound...]).trimmingCharacters(in: trimSet).prefix(300))
    }

    /// Strips the `STATUS: DONE` marker + separators from a sentinel line, returning the remainder
    /// (mirrors `reason(of:)` for the DONE form).
    private static func excerpt(of line: String) -> String {
        guard let r = line.range(of: "DONE", options: [.backwards, .caseInsensitive]) else { return "" }
        return String(String(line[r.upperBound...]).trimmingCharacters(in: trimSet).prefix(300))
    }

    /// Strips the sentinel's separators/backticks around the reason (em/en dashes, colons, ticks).
    private static let trimSet = CharacterSet(charactersIn: " `—–:-.\n\t")
}
