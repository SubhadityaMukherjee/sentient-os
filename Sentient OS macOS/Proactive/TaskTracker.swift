//
//  TaskTracker.swift
//  Sentient OS macOS
//
//  The user-maintained record of proactive tasks and their live status (open · on hold · closed).
//  Lives as a single markdown file at the vault root — `Tracked Tasks.md` — so the proactive judge
//  (PART 1) and research + prepare (PART 2) read it as part of the same knowledge base they
//  already reason over, and the user can edit it by hand without leaving the vault.
//
//  Why a file (and not a setting or a DB):
//   · Closed tasks would otherwise pile into Custom Instructions (the "proactive intelligence"
//     field), which is meant for standing directives, not a growing log of done work.
//   · Co-locating with the vault means the SAME surface the AI trusts for facts about the user's
//     life carries the status of the actions it surfaces — no separate channel to keep in sync.
//   · Hand-editable + UI-editable; the UI regenerates the file from its in-memory model on every
//     write, so the two never drift for the fields the UI owns.
//
//  Format (round-trips):
//
//    # Tracked Tasks
//
//    > one-paragraph explainer
//
//    ## Open
//    - Title — optional note _(added 2026-07-21)_ <!-- id:ABC123 -->
//
//    ## On Hold
//    - Title — reason _(since 2026-07-15)_ <!-- id:DEF456 -->
//
//    ## Closed
//    - Title — how resolved _(closed 2026-07-20)_ <!-- id:GHI789 -->
//
//  The HTML comment carries the stable id; everything else is human-readable. A hand-edit that
//  drops the id just gets a fresh one on the next UI write — no data loss, the title is the
//  human-meaningful key anyway.
//

import Foundation

struct TrackedTask: Sendable, Identifiable, Codable, Equatable {
    enum Status: String, Sendable, Codable, CaseIterable {
        case open, onHold, closed

        var label: String {
            switch self {
            case .open:   return "Open"
            case .onHold: return "On Hold"
            case .closed: return "Closed"
            }
        }
        /// The section header used in the markdown file.
        var sectionHeader: String {
            switch self {
            case .open:   return "## Open"
            case .onHold: return "## On Hold"
            case .closed: return "## Closed"
            }
        }
    }

    let id: String
    var title: String
    var status: Status
    var note: String         // optional context — "waiting on docs", "done yesterday", ""
    var date: Date           // status-effective date (added / since / closed)
}

actor TaskTracker {

    static let shared = TaskTracker()

    /// The on-disk file: `vaultRoot/Tracked Tasks.md`. Lives at the vault root so it sits next to
    /// the README and is read by the proactive prompts alongside the rest of the knowledge base.
    nonisolated static var fileURL: URL {
        VaultGenerator.vaultRoot.appendingPathComponent("Tracked Tasks.md")
    }

    private static let header = """
    # Tracked Tasks

    > Sentient's proactive judge reads this to avoid re-surfacing closed work and to resurface
    > on-hold items when context shifts. Edit by hand or via the Tracked Tasks window; Sentient
    > round-trips the file on every UI write. Drop the whole "—" suffix if there's no note.
    """

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: Read

    /// All tracked tasks, in `(status.sectionOrder, date desc)` order. Empty if the file is missing
    /// or unparseable (a corrupt file degrades to empty rather than throwing — the user can rebuild
    /// by hand; the AI sees nothing rather than garbage).
    func readAll() -> [TrackedTask] {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(raw)
    }

    /// A pre-formatted block ready to drop into a proactive prompt. Empty (→ caller omits the
    /// block) when there's nothing tracked yet.
    func renderForPrompt() -> String {
        let tasks = readAll()
        guard !tasks.isEmpty else { return "" }
        var out: [String] = []
        for status in [TrackedTask.Status.open, .onHold, .closed] {
            let group = tasks.filter { $0.status == status }
            if group.isEmpty { continue }
            out.append("### \(status.label)")
            for t in group {
                let noteSuffix = t.note.isEmpty ? "" : " — \(t.note)"
                out.append("- \(t.title)\(noteSuffix)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Write

    /// Ensure the file exists with a header. Idempotent. Called from the UI on first open and from
    /// the prompt builders (so a fresh vault gets the file before the AI reads it).
    func ensureExists() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.header.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            Log("TaskTracker.ensureExists: could not seed file — \(ErrorLabel(error))")
        }
    }

    /// Append one task at a given status. The typical entry point from a card's ✓ button
    /// (status = .closed) or the management view (any status).
    func add(title: String, status: TrackedTask.Status, note: String = "", date: Date = Date()) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var tasks = readAll()
        // De-dupe by title within the same status: clicking ✓ twice on equivalent cards (or a
        // hand-add that overlaps) shouldn't pile up duplicates. Different statuses are allowed —
        // an "open" task can also have a stale "closed" entry from months ago.
        if tasks.contains(where: { $0.status == status && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        tasks.append(TrackedTask(id: Self.shortID(), title: trimmed, status: status,
                                 note: note.trimmingCharacters(in: .whitespacesAndNewlines), date: date))
        write(tasks)
    }

    /// Move a task to a new status (and stamp a fresh status-effective date). No-op if not found.
    func setStatus(id: String, to status: TrackedTask.Status, note: String? = nil, date: Date = Date()) {
        var tasks = readAll()
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = status
        if let note { tasks[i].note = note }
        tasks[i].date = date
        write(tasks)
    }

    /// Drop a task entirely (vs. closing it, which keeps the record). Used by the management view.
    func remove(id: String) {
        var tasks = readAll()
        tasks.removeAll { $0.id == id }
        write(tasks)
    }

    /// Rewrite the file from the given model. The single write path — every mutation funnels here
    /// so the file's format and the parser's expectations can never drift apart.
    private func write(_ tasks: [TrackedTask]) {
        var lines: [String] = [Self.header, ""]
        for status in [TrackedTask.Status.open, .onHold, .closed] {
            lines.append(status.sectionHeader)
            let group = tasks.filter { $0.status == status }
            if group.isEmpty {
                lines.append("_(none yet)_")
            } else {
                for t in group.sorted(by: { $0.date > $1.date }) {
                    lines.append(Self.render(t))
                }
            }
            lines.append("")
        }
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: Self.fileURL, options: .atomic)
        } catch {
            Log("TaskTracker.write: could not persist — \(ErrorLabel(error))")
        }
    }

    // MARK: Rendering + parsing (the file format, in two functions)

    /// One bullet line for a task. Title is the human key; the `— note` suffix is omitted when
    /// empty; the date label is status-flavored ("added" / "since" / "closed"); the HTML comment
    /// carries the stable id for round-trips.
    private static func render(_ t: TrackedTask) -> String {
        let noteSuffix = t.note.isEmpty ? "" : " — \(t.note)"
        let verb: String
        switch t.status {
        case .open:   verb = "added"
        case .onHold: verb = "since"
        case .closed: verb = "closed"
        }
        return "- \(t.title)\(noteSuffix) _(\(verb) \(df.string(from: t.date)))_ <!-- id:\(t.id) -->"
    }

    /// Loose parse of the file into the model. Tolerates hand-edits: a missing id gets a fresh one,
    /// a missing date defaults to .now(), an unrecognized section is ignored. The title is whatever
    /// bullet text remains after stripping the trailing date-label and id-comment.
    private static func parse(_ raw: String) -> [TrackedTask] {
        var status: TrackedTask.Status?
        var out: [TrackedTask] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                status = TrackedTask.Status.allCases.first { $0.label.caseInsensitiveCompare(header) == .orderedSame }
                continue
            }
            guard let status, line.hasPrefix("- ") else { continue }
            let body = String(line.dropFirst(2))
            var id = shortID()
            var rest = body
            // Pull the trailing "<!-- id:XXX -->" if present (stable identity across rewrites).
            if let idCommentRange = body.range(of: #"<!--\s*id:\s*([A-Za-z0-9]+)\s*-->"#,
                                               options: .regularExpression) {
                let comment = String(body[idCommentRange])
                if let idRange = comment.range(of: #"id:[A-Za-z0-9]+"#, options: .regularExpression) {
                    id = String(comment[idRange].dropFirst("id:".count))
                }
                rest = body.replacingCharacters(in: idCommentRange, with: "")
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            // Pull the trailing "_(...)_" date label (display-only — we don't parse the date back
            // because the human phrasing is loose; default to .now() so a hand-added task still
            // sorts to the top of its section).
            let date = Date()
            if let labelRange = rest.range(of: #"_\([^)]*\)_\s*$"#, options: .regularExpression) {
                rest = rest.replacingCharacters(in: labelRange, with: "").trimmingCharacters(in: .whitespaces)
            }
            // Title and optional note split on the first " — " (em dash, the file's only splitter).
            var title = rest
            var note = ""
            if let emRange = rest.range(of: " — ") {
                title = String(rest[..<emRange.lowerBound])
                note = String(rest[emRange.upperBound...])
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            out.append(TrackedTask(id: id, title: title, status: status, note: note, date: date))
        }
        return out
    }

    /// A short, stable, URL-safe id (8 hex chars). Good enough for round-trip identity across
    /// rewrites; collisions are astronomically unlikely at this length.
    private static func shortID() -> String {
        let bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
