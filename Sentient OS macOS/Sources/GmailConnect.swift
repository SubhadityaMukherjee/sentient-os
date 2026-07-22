//
//  GmailConnect.swift
//  Sentient OS macOS
//
//  Gmail — the first CLOUD source (Google Calendar is the second, same shape — see CalendarConnect.swift).
//  Gmail can't be read on-device, so we both FETCH and SUMMARIZE through the user's own Codex Gmail
//  connector (account-level `codex_apps/gmail.*`, visible to `codex exec` even under
//  `--ignore-user-config` — measured live June 15, no CodexCLI change needed).
//
//  Connection: the user links Google on OpenAI's connector page (opened from CloudConnectSheet); we
//  confirm with `probeConnected()` — a `codex exec` that returns exactly YES/NO.
//
//  Reads (each summary is ONE ephemeral CycleNote in bucket "gmail"; the existing "tell cloud"
//  buttons add them to the vault, same as every other source):
//   • runInitial   — the last month as 4 WEEKLY `codex exec` calls, fired IN PARALLEL (one per
//                    week). Weekly chunking keeps each context window bounded (a heavy inbox
//                    measured at ~430 threads/week; one month in a single call would blow GPT-5.5's
//                    400k input cap); running the four concurrently makes the initial read ~4× faster.
//   • runIterative — everything since the saved high-water mark, in one call, then advance the mark.
//
//  The weekly prompt is DELIBERATELY disciplined: a naive "summarize this week" cost 220k tokens for
//  a mere count in testing (codex over-reads). It searches on metadata/snippets, caps at the newest
//  300 threads, and only opens the handful of threads that look genuinely important.
//
//  Doc: Documentation/Gmail Connector (Codex).md
//

import Foundation

enum GmailConnect {

    /// The single iterative-store bucket for Gmail. Its pointer is the high-water mark (run start).
    static let bucketKey = "gmail"

    /// OpenAI's hosted Gmail connector page — opened from CloudConnectSheet's "Connect Gmail".
    static let connectorURL = URL(string: "https://chatgpt.com/plugins/plugin_connector_1p_95d39881713c8191931482a62d6edff9?q=gmail")!

    /// Newest-N threads per read (the connector-limits doc's cap; a heavy week exceeds it).
    private static let threadCap = 300
    private static let initialWeeks = 4

    enum GmailError: LocalizedError {
        case dateMath
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .dateMath: return "Gmail date math failed."
            case .failed(let m): return m
            }
        }
    }

    /// Parsed weekly/iterative read result (from the structured codex reply).
    private struct ReadResult: Sendable {
        let summary: String
        let hasActionItems: Bool
        let threadCount: Int
    }

    /// One initial-run weekly window: its display label, the exact codex prompt, and the date the
    /// resulting CycleNote is stamped with (the window's last day).
    private struct Window: Sendable {
        let label: String
        let prompt: String
        let itemDate: Date
    }

    /// A finished window paired with its read (nil ⇒ nothing notable) — what each parallel task returns.
    private struct WindowResult: Sendable {
        let window: Window
        let result: ReadResult?
    }

    /// Structured progress for the dev processing UI. The initial run fires all windows in PARALLEL,
    /// so events arrive in completion order, not week order: `completed` (windows finished so far,
    /// 1...total) drives the bar; `keptSoFar` is how many produced a summary. `prompt` is the exact
    /// Codex ask (shown in the processing view's PROMPT pane); `summary` is nil when nothing notable.
    enum Progress: Sendable {
        case windowStart(total: Int, label: String, prompt: String)
        case windowDone(total: Int, label: String, summary: String?, threads: Int,
                        completed: Int, keptSoFar: Int)
    }

    // MARK: - Connection probe (the "I'm done" YES/NO check)

    /// One probe — DISABLED in phase 1 (Gmail connector was codex's MCP; needs the agent loop).
    /// ponytail: phase-2 restores when the agent loop has MCP-tool support.
    static func probeConnected() async -> Bool { false }

    // MARK: - Initial read (last month → 4 weekly summaries)

    /// Fresh start. DISABLED in phase 1 — codex MCP connector was the only Gmail read path.
    @discardableResult
    static func runInitial(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        throw GmailError.failed("Gmail needs the local-LLM agent loop (phase 2).")
    }

    // MARK: - Iterative read (since the high-water mark)

    /// Iterative read. DISABLED in phase 1.
    @discardableResult
    static func runIterative(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        throw GmailError.failed("Gmail needs the local-LLM agent loop (phase 2).")
    }

    // MARK: - One read (a single agent call over a date window)

    private static func read(prompt: String) async throws -> ReadResult? {
        _ = try await LocalLLM.shared.runAgent(prompt)   // throws agentLoopDisabled
        return nil
    }

    private static func record(_ r: ReadResult, itemDate: Date, label: String) async {
        let sid = "gmail:\(Int(itemDate.timeIntervalSince1970))"          // unique per window
        await CycleStore.shared.recordNote(
            bucketKey: bucketKey, kind: .gmail, sourceID: sid, folder: "Gmail",
            itemDate: itemDate, text: r.summary, title: "Email · \(label)",
            reminderFlagged: r.hasActionItems)
    }

    /// Tolerant parse of the structured reply (output-schema makes `result` the JSON; still fence-safe).
    /// §7.10: SHAPE MISMATCH (JSON won't parse, or the required `notable` key is absent — despite the
    /// output-schema) is a codex/schema regression → event. A QUIET week (`notable:false` / empty
    /// summary) is normal → silent. Distinguishing them stops a broken Gmail leg from hiding as "quiet".
    private static func parse(_ result: String) -> ReadResult? {
        let span: String
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            span = String(result[s...e])
        } else { span = result }
        guard let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            shapeMismatch(missing: "json", len: result.count)
            return nil
        }
        guard let notable = obj["notable"] as? Bool else {
            shapeMismatch(missing: "notable", len: result.count)    // key names only — never values
            return nil
        }
        // From here a nil return is a QUIET week — NOT an anomaly, so no event.
        guard notable, let summary = obj["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReadResult(summary: summary,
                          hasActionItems: obj["has_action_items"] as? Bool ?? false,
                          threadCount: obj["thread_count"] as? Int ?? 0)
    }

    private static func shapeMismatch(missing: String, len: Int) {
        CrashReporting.captureEvent("gmail.parse.shape_mismatch", level: .warning,
            tags: ["source": "gmail"], extra: ["missing": missing, "result_len": String(len)],
            fingerprint: ["gmail", "parse", "shape_mismatch"])
    }

    // MARK: - Date helpers

    private static func qDate(_ d: Date) -> String {     // Gmail query date: yyyy/MM/dd
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.timeZone = .current
        return f.string(from: d)
    }
    private static func label(_ d: Date) -> String {     // display: "Jun 8"
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = .current
        return f.string(from: d)
    }

    // MARK: - Prompts

    private static let probePrompt = """
    Using your Gmail connector tools, check whether you can read this account's Gmail inbox. \
    Reply with EXACTLY YES if you can, or EXACTLY NO if the Gmail connector is not available. \
    Output only that one word and nothing else.
    """

    /// The structured reply contract — one dense weekly summary plus the flags Sentient keys on.
    private static let weeklySchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "thread_count":{"type":"integer"},\
    "notable":{"type":"boolean"},\
    "has_action_items":{"type":"boolean"},\
    "summary":{"type":"string"}},\
    "required":["thread_count","notable","has_action_items","summary"]}
    """

    private static func weeklyPrompt(query: String, label: String) -> String {
        """
        You are the Gmail intelligence pass for Sentient OS, a privacy-first personal-AI app. \
        Summarize ONE window of the user's email (\(label)) into a single dense summary that feeds \
        two things: the user's personal knowledge base, and a PROACTIVE engine that surfaces things \
        needing the user's attention. Finding what genuinely matters is the whole job.

        ## Fetch — be efficient, the inbox is heavy
        - Use `gmail.search_emails` with EXACTLY this query: `\(query)`
        - Consider at most the newest \(threadCap) threads in that window; if there are more, take the \
        newest \(threadCap).
        - Work from subjects, senders, and snippets. Open a thread with `gmail.read_email` ONLY when it \
        looks genuinely important — a real request directed at the user, a deadline, a booking/renewal \
        window, or a personal/financial/work matter. DO NOT open newsletters, marketing, receipts, or \
        automated notifications, and DO NOT read every email. Over-reading wastes the budget.

        ## Produce ONE summary (third person — "the user")
        - Lead with a short overview of what actually mattered this window.
        - Then a clear section **Action items / awaiting the user / deadlines / commitments**: each as \
        `who · what · by when`. Only real, still-actionable ones; skip anything stale or trivial.
        - Then: key people and threads, and anything else genuinely important about the user's life, \
        work, money, plans, or relationships.

        ## Rules
        - Curate RUTHLESSLY. Skip spam, newsletters, marketing, promotions, and automated noise unless \
        truly important. A quiet window with nothing worth keeping → `notable: false`, `summary: ""`.
        - PII-light: NEVER include full card/account numbers, passwords, verification/2FA codes, or \
        verbatim sensitive medical or financial figures. Summarize, never transcribe such details.
        - Truth & attribution: an email FROM someone else is THEIR words, not the user's. Never assert \
        something about the user the email doesn't support.

        ## Output
        Return ONLY the JSON object matching the schema: `thread_count` (threads you considered, after \
        the cap), `notable` (anything worth a knowledge-base note?), `has_action_items` (anything the \
        proactive engine should weigh?), and `summary` (the dense text; empty string when not notable).
        """
    }
}
