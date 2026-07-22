//
//  RealtimeScheduler.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  The periodic in-app scheduler. Fires every ~20 min while Sentient is open and the feature is on,
//  catching summaries that arrived since the last tick and running the additive realtime pipeline
//  on them. Stays in its lane: it ONLY does fast judge + research on high-urgency survivors + merge
//  into the deck (`ProactiveCycle.runRealtimeIncrement`). It does NOT touch the knowledge base fold,
//  MCP mirror, GiftLetter, or the CycleStore wipe — those stay owned by the 3 AM overnight cycle,
//  which is still the single source of truth for durable memory.
//
//  The tick reuses the SAME sync machinery the 3 AM run uses (IterativeRun .auto over the connected
//  on-device connectors + the Gmail/Calendar iterative legs), so source detection and processing are
//  byte-for-byte identical — only the post-read tail is the lighter realtime increment, not the full
//  ProactiveCycle.
//
//  Skip conditions on each tick (mirrors OvernightScheduler.runProcessing's gates):
//   - `!LocalLLMConfig.isConfigured` (free/go plan): no proactive quota to spend on ticks.
//   - `PipelineActivity.shared.isRunning`: a full cycle, Analyze Now, or another tick is in flight.
//   - `PowerState.overnightBlockReason`: don't hammer the GPU on battery / Low Power / thermal.
//
//  "What's new" tracking: CycleNote carries `createdAt` (when it landed in CycleStore). We persist
//  `realtime.lastRunAt` and on each tick consider only notes with `createdAt > lastRunAt`. The 3 AM
//  cycle still wipes CycleStore at the end of its run, so notes accumulate during the day and realtime
//  is a pure additive consumer — no interference with the overnight KB fold.
//

import Foundation
import ServiceManagement

@MainActor
@Observable
final class RealtimeScheduler {

    static let shared = RealtimeScheduler()

    /// One-line status for the dev UI ("off" / "idle (next in 20m)" / "syncing…" / "running on N new…").
    var statusLine = "off"

    // PRODUCTION toggle (Settings), DEV override (cockpit), and the dev interval override. The two
    // enable keys mirror OvernightScheduler's split: a dev testing the cockpit never trips the
    // production latch, and the production flag is what Settings + onboarding write.
    static let enabledKey = "realtime.enabled"                  // PRODUCTION (Settings)
    static let devEnabledKey = "dbg.realtime.enabled"           // DEV override (cockpit)
    static let intervalKey = "dbg.realtime.intervalSeconds"     // DEV override of the 20-min default
    static let lastRunAtKey = "realtime.lastRunAt"              // Double epoch — the "what's new" cursor
    static let defaultInterval: TimeInterval = 20 * 60          // 20 min — "real-time enough" without burning quota

    /// The configured interval (dev override wins; otherwise the 20-min default).
    nonisolated static var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        return v > 0 ? v : defaultInterval
    }

    /// When the last realtime tick ran (nil until the first one completes).
    nonisolated static var lastRunAt: Date? {
        let t = UserDefaults.standard.double(forKey: lastRunAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Enabled if EITHER the production flag or the dev override is on.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) || UserDefaults.standard.bool(forKey: devEnabledKey)
    }

    private var loopTask: Task<Void, Never>?

    /// Call on launch and on any toggle. Idempotent — starts the loop if enabled, stops it otherwise.
    func reevaluate() {
        if Self.isEnabled { start() } else { stop() }
    }

    /// Fire one tick immediately (the dev "Fire realtime now" button). Bypasses the interval wait
    /// but still honors every skip gate. Idempotent if a tick is already running.
    func fireNow() {
        Task { await tick() }
    }

    private func start() {
        loopTask?.cancel()
        loopTask = Task { await loop() }
        statusLine = "armed (every \(Int(Self.interval / 60))m)"
    }

    private func stop() {
        loopTask?.cancel(); loopTask = nil
        statusLine = "off"
    }

    /// Sleep-then-tick loop. Sleeps FIRST so a fresh launch waits one interval before the first tick
    /// (avoids hammering on a rapid restart loop, gives any in-flight 3 AM cycle room to finish, and
    /// lets the dev "armed" statusLine be visible before work begins).
    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { break }
            await tick()
        }
    }

    /// The body: sync → check for new notes → run the realtime increment if anything's new.
    private func tick() async {
        // Skip conditions — same gates as OvernightScheduler.runProcessing.
        guard LocalLLMConfig.isConfigured else { return }
        guard !PipelineActivity.shared.isRunning else {
            statusLine = "skipped (pipeline busy)"
            return
        }
        if let blocked = PowerState.overnightBlockReason() {
            statusLine = "skipped (\(blocked))"
            return
        }

        statusLine = "syncing…"
        Analytics.signal("Realtime.tickStarted")

        // 1) On-device sources via IterativeRun .auto (per-bucket: initial-if-fresh, iterative-if-caught-up).
        //    Identical to the 3 AM / Analyze Now read leg.
        let fda = Permissions.hasFullDiskAccess()
        let sources = SourceSelection.current(fdaGranted: fda)
        let connectors = RunSource.connectors(from: sources)
        if !connectors.isEmpty, let modelPath = ModelLocator.resolve() {
            _ = await IterativeRun(modelPath: modelPath).run(connectors, mode: .auto) { _ in }
        }

        // 2) Cloud legs — same gates as the 3 AM run (connected + run-flag on).
        let runGmail = ud("dbg.gmail.connected") && ud("dbg.run.gmail")
        let runCalendar = ud("dbg.calendar.connected") && ud("dbg.run.calendar")
        if runGmail    { try? await GmailConnect.runIterative { _ in } }
        if runCalendar { try? await CalendarConnect.runIterative { _ in } }

        // 3) Find what's new since the last realtime tick. CycleStore.notes() is everything since the
        //    last 3 AM wipe; we want only what appeared AFTER our previous tick.
        let now = Date()
        let cutoff = Self.lastRunAt ?? .distantPast
        let newNotes = await CycleStore.shared.notes()
            .filter { $0.createdAt > cutoff }
            .map(CloudNote.init)
        if newNotes.isEmpty {
            statusLine = "idle (next in \(Int(Self.interval / 60))m)"
            Analytics.signal("Realtime.tickIdle")
            return
        }

        // 4) Live calendar context, same as the full cycle (only when Calendar is connected).
        var calCtx: String?
        if UserDefaults.standard.bool(forKey: "dbg.calendar.connected") {
            calCtx = await CalendarConnect.fetchProactiveContext()
        }

        // 5) The realtime increment — fast judge + research on high-urgency + merge into the deck.
        statusLine = "running on \(newNotes.count) new…"
        let failure = await ProactiveCycle.shared.runRealtimeIncrement(newNotes: newNotes, calendarContext: calCtx)
        if failure != nil {
            statusLine = "last tick failed"
            Analytics.signal("Realtime.tickFailed")
        } else {
            statusLine = "idle (next in \(Int(Self.interval / 60))m)"
            Analytics.signal("Realtime.tickDone")
        }

        // 6) Advance the cursor — these notes are now "seen" by realtime. The 3 AM cycle still folds
        //    them into the KB and wipes CycleStore, so this cursor is a SECONDARY "realtime has looked
        //    at this" mark, not a claim on the data.
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastRunAtKey)
    }

    private func ud(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}
