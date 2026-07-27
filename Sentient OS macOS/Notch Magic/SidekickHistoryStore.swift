//
//  SidekickHistoryStore.swift
//  Sentient OS macOS
//
//  The durable log of "what Sidekick did for me" — one row per real run (the command bar, right-⌘
//  hold-to-talk, or a proactive card's fire). The onboarding notch demo is NEVER recorded (it calls
//  `finish()` directly, bypassing the `complete`/`completeExternal` hooks that write here). Each row
//  carries the ask, the outcome, the agent's own one-line "what I did" (the STATUS sentinel's
//  summary for a DONE, the reason for a COULD_NOT), and how long it ran.
//
//  Its OWN on-disk container (isolated from CycleStore and the old Store, so a schema change here
//  can never wipe either of them). Same isolation philosophy as CycleStore — only this actor touches
//  the @Model; callers pass the Sendable `SidekickRunDraft` in and get `SidekickRunItem` snapshots out.
//
//  Privacy: command + summary are user content (same tier as the knowledge-base vault). They live
//  ONLY on disk + on the user's screen — never TelemetryDeck/Sentry.
//

import Foundation
import SwiftData

// MARK: - Outcome

enum SidekickOutcome: String, Sendable, Codable {
    case success, stopped, failed
}

// MARK: - Model

@Model
final class SidekickRun {
    @Attribute(.unique) var id: UUID
    var promptedAt: Date          // runStarted — when the ask was submitted
    var command: String           // the ask (truncated at capture time)
    var mode: String              // AgentMode.rawValue ("computer" / …)
    var source: String            // who triggered it (promptBar / voice / proactive_card / …)
    var outcome: String           // SidekickOutcome.rawValue
    var summary: String           // the agent's one-line "what I did" / reason; "" if none
    var durationSeconds: Double
    var completedAt: Date

    init(id: UUID = UUID(), promptedAt: Date, command: String, mode: String, source: String,
         outcome: SidekickOutcome, summary: String, durationSeconds: Double, completedAt: Date = Date()) {
        self.id = id
        self.promptedAt = promptedAt
        self.command = command
        self.mode = mode
        self.source = source
        self.outcome = outcome.rawValue
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
    }
}

// MARK: - Value types (Sendable bridges across the actor boundary)

/// The write payload — everything `complete()` / `completeExternal()` hands to the store.
struct SidekickRunDraft: Sendable {
    let promptedAt: Date
    let command: String
    let mode: String
    let source: String
    let outcome: SidekickOutcome
    let summary: String
    let durationSeconds: Double
}

/// A Sendable snapshot of one run — what the history view consumes.
struct SidekickRunItem: Identifiable, Sendable, Codable {
    let id: UUID
    let promptedAt: Date
    let command: String
    let mode: String
    let source: String
    let outcome: SidekickOutcome
    let summary: String
    let durationSeconds: Double
    let completedAt: Date
}

// MARK: - The actor

@ModelActor
actor SidekickHistoryStore {

    /// Record one completed run. Fire-and-forget from the completion hooks; a save failure is logged
    /// (history is a convenience, not a correctness path) but never blocks the run's epilogue.
    func record(_ draft: SidekickRunDraft) {
        let run = SidekickRun(promptedAt: draft.promptedAt, command: draft.command, mode: draft.mode,
                              source: draft.source, outcome: draft.outcome, summary: draft.summary,
                              durationSeconds: draft.durationSeconds)
        modelContext.insert(run)
        do {
            try modelContext.save()
        } catch {
            Log("SidekickHistory.record failed: \(ErrorLabel(error))")
            CrashReporting.capture(error)
            modelContext.rollback()
        }
    }

    /// The most recent runs, newest-first. The view asks for a bounded window (history is a "what
    /// just happened" surface, not an archive).
    func recent(limit: Int = 200) -> [SidekickRunItem] {
        var descriptor = FetchDescriptor<SidekickRun>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map(item(from:))
    }

    func count() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<SidekickRun>())) ?? 0
    }

    func clearAll() {
        do {
            try modelContext.delete(model: SidekickRun.self)
            try modelContext.save()
        } catch {
            Log("SidekickHistory.clearAll failed: \(ErrorLabel(error))")
            CrashReporting.capture(error)
        }
    }

    private func item(from r: SidekickRun) -> SidekickRunItem {
        SidekickRunItem(id: r.id, promptedAt: r.promptedAt, command: r.command, mode: r.mode,
                        source: r.source,
                        outcome: SidekickOutcome(rawValue: r.outcome) ?? .failed,
                        summary: r.summary, durationSeconds: r.durationSeconds, completedAt: r.completedAt)
    }
}

// MARK: - Shared instance (its own container)

extension SidekickHistoryStore {
    /// The app-wide history, backed by its OWN on-disk store ("SidekickHistory.store" under the
    /// namespaced `SentientOS` root in Application Support). Wipe-and-retry-once on an incompatible
    /// schema change (dev convenience — mirrors CycleStore).
    static let shared: SidekickHistoryStore = {
        let schema = Schema([SidekickRun.self])
        let url = URL.sentientSupport.appending(path: "SidekickHistory.store")
        let config = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return SidekickHistoryStore(modelContainer: container)
        }
        for sfx in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + sfx))
        }
        guard let container = try? ModelContainer(for: schema, configurations: config) else {
            fatalError("SidekickHistoryStore: could not create its ModelContainer")
        }
        return SidekickHistoryStore(modelContainer: container)
    }()
}
