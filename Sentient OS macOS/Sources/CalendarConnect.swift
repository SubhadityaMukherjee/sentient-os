//
//  CalendarConnect.swift
//  Sentient OS macOS
//
//  Google Calendar — a CLOUD source, twin to Gmail (GmailConnect). The calendar can't be read
//  on-device, so we both FETCH and SUMMARIZE through the user's own Codex Google Calendar connector
//  (account-level `codex_apps/google_calendar.*` — get_profile / search_events / read_event, visible
//  to `codex exec` whether or not `--ignore-user-config` is passed; verified live June 21).
//
//  Connection: the user links Google on OpenAI's connector page (opened from CloudConnectSheet); we
//  confirm with `probeConnected()` — a `codex exec` that returns exactly YES/NO.
//
//  Reads (each summary is ONE ephemeral CycleNote in bucket "calendar"; the existing "tell cloud"
//  buttons fold them into the vault, same as every other source):
//   • runInitial   — the last YEAR as 12 MONTHLY `codex exec` calls, newest month first. One dense
//                    summary per month, keeping ONLY the genuinely important events (drops standups,
//                    lunches, focus-time blocks, and other routine noise).
//   • runIterative — everything since the saved high-water mark, in one call, then advance the mark.
//
//  Proactive (the one thing Gmail doesn't have): `fetchProactiveContext()` — a SEPARATE read that
//  dumps the user's LAST 7 DAYS + NEXT 24 HOURS of events (ALL of them, uncurated) as a compact text
//  block. That block is injected into BOTH proactive stages (Proactive.findActionItems and
//  ProactiveResearch.researchAndPrepare) so the engine knows what's actually on the user's calendar.
//
//  Writes (add an event) are NOT here — that's ProactiveExecutor.fireCalendar, which runs
//  sandboxed with the write tools pre-approved per run (`approveConnectorWrites`; the calendar
//  write tools are approval-gated and auto-cancel headless otherwise, exactly like Gmail's
//  send_email — verified live June 21). All reads here are read-only and need no special config.
//
//  Doc: Documentation/Calendar Connector (Codex).md
//

import Foundation

enum CalendarConnect {

    /// The single iterative-store bucket for Calendar. Its pointer is the high-water mark (run start).
    static let bucketKey = "calendar"

    /// OpenAI's hosted Google Calendar connector page — opened from CloudConnectSheet's "Connect Calendar".
    static let connectorURL = URL(string: "https://chatgpt.com/plugins/plugin_connector_1p_f8509de903288191b14a160c6c5d20b0?q=calendar")!

    /// Newest-N events per read window (a busy month rarely exceeds this; a guard against a runaway list).
    private static let eventCap = 200
    private static let initialMonths = 12

    enum CalendarError: LocalizedError {
        case dateMath
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .dateMath: return "Calendar date math failed."
            case .failed(let m): return m
            }
        }
    }

    /// Parsed monthly/iterative read result (from the structured codex reply).
    private struct ReadResult {
        let summary: String
        let hasActionItems: Bool
        let eventCount: Int
    }

    /// Structured progress for the dev processing UI — each date window (a month, or the iterative
    /// since-mark window) STARTING then FINISHING. `prompt` is the exact Codex ask (shown in the
    /// processing view's PROMPT pane); `summary` is nil when the window had nothing notable.
    enum Progress: Sendable {
        case windowStart(step: Int, total: Int, label: String, prompt: String)
        case windowDone(step: Int, total: Int, label: String, summary: String?, events: Int, keptSoFar: Int)
    }

    // MARK: - Connection probe (the "I'm done" YES/NO check)

    /// DISABLED in phase 1 — Calendar connector was codex's MCP; needs the agent loop.
    /// ponytail: phase-2 restores when the agent loop has MCP-tool support.
    static func probeConnected() async -> Bool { false }

    // MARK: - Initial read (last year → 12 monthly summaries)

    /// DISABLED in phase 1.
    @discardableResult
    static func runInitial(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        throw CalendarError.failed("Calendar needs the local-LLM agent loop (phase 2).")
    }

    // MARK: - Iterative read (since the high-water mark)

    /// DISABLED in phase 1.
    @discardableResult
    static func runIterative(onProgress: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> Int {
        throw CalendarError.failed("Calendar needs the local-LLM agent loop (phase 2).")
    }

    // MARK: - Proactive context (last 7 days + next 24 hours — ALL events, uncurated)

    /// DISABLED in phase 1 — was a codex MCP read.
    static func fetchProactiveContext() async -> String? { nil }

    // MARK: - One read (a single agent call over a date window)

    private static func read(prompt: String) async throws -> ReadResult? {
        _ = try await LocalLLM.shared.runAgent(prompt)   // throws agentLoopDisabled
        return nil
    }

    private static func record(_ r: ReadResult, itemDate: Date, label: String) async {
        let sid = "calendar:\(Int(itemDate.timeIntervalSince1970))"        // unique per window
        await CycleStore.shared.recordNote(
            bucketKey: bucketKey, kind: .calendar, sourceID: sid, folder: "Calendar",
            itemDate: itemDate, text: r.summary, title: "Calendar · \(label)",
            reminderFlagged: r.hasActionItems)
    }

    /// Tolerant parse of the structured read reply (output-schema makes `result` the JSON; fence-safe).
    /// §7.11: SHAPE MISMATCH (no JSON, or the required `notable` key absent — despite the output-schema)
    /// is a codex/schema regression → event; a QUIET window (`notable:false` / empty summary) is normal
    /// → silent. Distinguishes a broken Calendar leg from an empty calendar.
    private static func parse(_ result: String) -> ReadResult? {
        guard let span = jsonSpan(result),
              let data = span.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            shapeMismatch(missing: "json", len: result.count)
            return nil
        }
        guard let notable = obj["notable"] as? Bool else {
            shapeMismatch(missing: "notable", len: result.count)    // key names only — never values
            return nil
        }
        // From here a nil return is a QUIET window — NOT an anomaly, so no event.
        guard notable, let summary = obj["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReadResult(summary: summary,
                          hasActionItems: obj["has_action_items"] as? Bool ?? false,
                          eventCount: obj["event_count"] as? Int ?? 0)
    }

    private static func shapeMismatch(missing: String, len: Int) {
        CrashReporting.captureEvent("calendar.parse.shape_mismatch", level: .warning,
            tags: ["source": "calendar"], extra: ["missing": missing, "result_len": String(len)],
            fingerprint: ["calendar", "parse", "shape_mismatch"])
    }

    /// Widest `{ … }` span in a possibly-fenced reply.
    private static func jsonSpan(_ result: String) -> String? {
        if let s = result.firstIndex(of: "{"), let e = result.lastIndex(of: "}"), s < e {
            return String(result[s...e])
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Date helpers

    /// ISO-8601 with timezone offset — a precise window boundary the connector can bound on.
    private static func iso(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
    private static func label(_ d: Date) -> String {     // display: "Jun 8"
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = .current
        return f.string(from: d)
    }

    // MARK: - Prompts

    private static let probePrompt = """
    Using your Google Calendar connector tools, check whether you can read this account's Google \
    Calendar. Reply with EXACTLY YES if you can, or EXACTLY NO if the Google Calendar connector is not \
    available. Output only that one word and nothing else.
    """

    /// The structured read reply — one dense window summary plus the flags Sentient keys on.
    private static let readSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "event_count":{"type":"integer"},\
    "notable":{"type":"boolean"},\
    "has_action_items":{"type":"boolean"},\
    "summary":{"type":"string"}},\
    "required":["event_count","notable","has_action_items","summary"]}
    """

    private static func readPrompt(range: String, label: String) -> String {
        """
        You are the Google Calendar intelligence pass for Sentient OS, a privacy-first personal-AI app. \
        Summarize ONE window of the user's calendar (\(label)) into a single dense summary that feeds \
        two things: the user's personal knowledge base, and a PROACTIVE engine that surfaces things \
        needing the user's attention. Finding what genuinely matters is the whole job.

        ## Fetch
        - Use ONLY your Google Calendar connector tools (do NOT web search). Search the user's primary \
        calendar for events \(range).
        - Consider at most the \(eventCap) most relevant events in that window. Open an event's details \
        only when it looks genuinely important.

        ## Keep ONLY what matters — curate RUTHLESSLY
        A calendar is mostly routine. KEEP the events that say something real about the user's life, \
        work, relationships, or plans — meaningful meetings, interviews, trips, appointments, \
        deadlines, events with specific people, anything with stakes. DROP the noise: recurring \
        standups, "Lunch", "Focus time"/"Do not schedule" blocks, generic holds, declined events, and \
        anything trivial or automated. A quiet window with nothing worth keeping → `notable: false`, \
        `summary: ""`.

        ## Produce ONE summary (third person — "the user")
        - Lead with a short overview of what actually mattered this window.
        - Note the key meetings/events and the people involved, and any commitments, deadlines, or \
        follow-ups they imply (each as `who · what · when`).
        - Anything else genuinely important about the user's life, work, plans, or relationships.

        ## Rules
        - Truth & attribution: a calendar event is the user's SCHEDULE, not a claim about who they are. \
        An event with other people is something they're attending — don't infer someone else's job, \
        biography, or project onto the user.
        - PII-light: summarize, never transcribe sensitive details (e.g. medical specifics, full \
        meeting-link tokens, dial-in PINs).

        ## Output
        Return ONLY the JSON object matching the schema: `event_count` (events you considered), \
        `notable` (anything worth a knowledge-base note?), `has_action_items` (anything the proactive \
        engine should weigh — an upcoming commitment, a deadline, a follow-up?), and `summary` (the \
        dense text; empty string when not notable).
        """
    }

    /// The proactive-fetch reply — a compact text dump of recent + imminent events (uncurated).
    private static let proactiveSchema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "connected":{"type":"boolean"},\
    "events_text":{"type":"string"}},\
    "required":["connected","events_text"]}
    """

    private static let proactiveFetchPrompt = """
    You are the calendar-fetch step for Sentient OS's Proactive Intelligence engine. Using ONLY your \
    Google Calendar connector tools (do NOT web search), list the user's events in TWO windows on their \
    primary calendar. List ALL of them — do NOT filter by importance; the proactive engine wants the \
    full picture (an empty slot is as useful as a meeting).

    Windows (use the account's local timezone):
    - LAST 7 DAYS: events whose start is within the last 7 days (up to now).
    - NEXT 24 HOURS: events whose start is within the next 24 hours (from now).

    For each event, one compact line: `date + start–end time · title · location (if any) · N other \
    attendees (if any) · status (if not "confirmed")`. List each window chronologically under a clear \
    heading. If a window has no events, write "(none)". Keep it tight — no commentary, just the lists.

    Return ONLY the JSON object matching the schema: `connected` (true if you could read the calendar; \
    false if the connector wasn't available) and `events_text` (the two labeled lists). If the \
    connector isn't available, set `connected: false` and `events_text: ""`.
    """
}
