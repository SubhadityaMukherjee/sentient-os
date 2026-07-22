//
//  ProactiveExecutor.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — PART 3 of 3: THE EXECUTOR. On the user's one-button press it actually
//  FIRES a `PreparedAction` that PART 2 staged. Real channels, picked by `method`:
//    • gmail    → the user's Gmail connector (MCP) via codex — SANDBOXED (`read-only` Seatbelt),
//      with the connector write tools pre-approved for the one run (`approveConnectorWrites`);
//      no bypass. Email always goes through the connector (Google device-binds web sessions),
//      never a browser.
//    • calendar → the user's calendar tool/MCP via codex, same sandboxed pre-approval (real if one
//      is configured; honest if not).
//    • computer → the user's Mac directly via codex computer use (bypass-sandbox — required: the
//      computer-use plugin's per-app elicitations auto-deny headless under any Seatbelt profile).
//      This also covers logged-in WEBSITE tasks (register / RSVP / buy / fill a form) by driving
//      the user's real browser.
//    • research → a briefing to read → surfaced honestly (not fired).
//  The user-editable artifact (`preparedContent`) rides in a <CONTENT> block: the verbatim text for
//  sends, the step-by-step PLAN for computer tasks; `executionRecipe` is routing only — so the
//  user's edits are exactly what fires.
//
//  The computer channel is the one bypass-sandbox run, so there the wrapper PROMPT is the only
//  safety layer — every wrapper is app-authored + fixed, treats the recipe AND page content as
//  DATA (injection guard), and fires exactly the one declared action. Mirrors the actor shape of
//  Proactive / ProactiveResearch.
//
//  Key methods:
//   - fire(_:progress:)  → Outcome   (routes on kind, runs the real channel, cleans up)
//
//  Doc: Documentation/Proactive Intelligence (Judge).md
//

import Foundation

actor ProactiveExecutor {

    static let shared = ProactiveExecutor()

    /// The result of one fire. `fired` = the channel acted (carries codex's summary of what it did);
    /// `notFireable` = no channel for this kind / prerequisite missing (honest, nothing happened);
    /// `failed` = a real attempt that errored or the agent reported it couldn't.
    enum Outcome: Sendable {
        case fired(String)
        case notFireable(String)
        case failed(String)
    }

    /// Kinds the executor can actually act on today. `message` has no send channel; `research` /
    /// `reminder` carry no action (`execution_recipe == "none"`).
    static func isFireable(_ method: PreparedAction.Method) -> Bool {
        switch method {
        case .computer, .gmail, .calendar: return true
        case .research:                    return false   // a briefing to read — nothing to fire
        }
    }

    // MARK: Fire

    /// PART 3 — fire one prepared action. DISABLED in phase 1 — every channel (gmail, calendar,
    /// computer use) needs the agent loop. ponytail: phase-2 restores each one as the agent loop +
    /// phase-4 computer-use work land.
    func fire(_ action: PreparedAction, progress: @escaping @Sendable (String) -> Void) async -> Outcome {
        return .notFireable("Firing actions needs the local-LLM agent loop (phase 2).")
    }

    // MARK: util

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
