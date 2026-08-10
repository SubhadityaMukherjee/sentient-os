//
//  VaultCloud.swift
//  Sentient OS macOS
//
//  The iterative system's two knowledge-base cloud calls, through the user's own Codex CLI (CodexCLI):
//   • create    — "go make knowledge base exist": build the vault from scratch. Reuses
//                 VaultGenerator (staging dir + atomic swap + usage-limit resume).
//   • update    — "go update knowledge base": merge the cycle's new notes into the existing vault
//                 with surgical edits on the live vault (eval-validated prompt lifted from the old
//                 VaultUpdater; no store queue — the cycle's notes are wiped wholesale each cycle).
//
//  Proactive intelligence is its OWN module — see Proactive/ (ProactiveCycle owns the sequencing).
//  Connector-agnostic: operates on `CycleStore.notes()` regardless of source (files / notes / chats).
//  Create/update only MARK the vault dirty; MCP sync is a SEPARATE step (the dev "MCP SYNC" button →
//  MirrorClient.push, plus pushIfDirty() as the on-launch catch-up). Re-couple in markDirty() later.
//

import Foundation

/// A Sendable, store-agnostic description of one summary handed to a Codex call. Decouples the
/// cloud prompts from any particular store. Built from a CycleNoteItem (the iterative system).
/// Codable for CorpusSlicer's staging snapshot (multi-slice resume determinism).
struct CloudNote: Sendable, Codable {
    let kind: SourceKind
    let sourceID: String       // "file:<abs path>" / "notes:<uuid>" — VaultGenerator.locSrc keys on it
    let folder: String
    let title: String?
    let text: String
    let itemDate: Date?

    init(kind: SourceKind, sourceID: String, folder: String, title: String?, text: String, itemDate: Date?) {
        self.kind = kind; self.sourceID = sourceID; self.folder = folder
        self.title = title; self.text = text; self.itemDate = itemDate
    }

    /// From an iterative cycle note.
    init(_ n: CycleNoteItem) {
        self.init(kind: n.kind, sourceID: n.sourceID, folder: n.folder,
                  title: n.title, text: n.text, itemDate: n.itemDate)
    }
}

actor VaultCloud {

    static let shared = VaultCloud()

    // DURABLE resume handles for BOTH build and update (B11): each carries a codex session id + the
    // staging dir holding the work-in-progress, persisted to UserDefaults so a usage limit or an app
    // restart RESUMES instead of re-running the expensive codex call from scratch. Both the build and
    // update paths now stage-then-swap (the live vault is never mutated mid-run), so a lost handle is
    // only wasteful, never corrupting.
    private var createResume: VaultGenerator.ResumeToken?
    private var updateResume: VaultGenerator.ResumeToken?
    private static let createResumeKey = "vault.create.resume"
    private static let updateResumeKey = "vault.update.resume"

    init() {
        createResume = Self.loadResume(Self.createResumeKey)
        updateResume = Self.loadResume(Self.updateResumeKey)
    }

    /// Load a persisted resume token, discarding it (and its stale key) if it can't actually resume:
    /// nothing durable to continue (no session to reopen AND no completed slices in staging), or
    /// the staging dir is gone (deleted / disk cleaned).
    private static func loadResume(_ key: String) -> VaultGenerator.ResumeToken? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: data),
              t.sessionID != nil || (t.sliceIndex ?? 0) > 0,
              FileManager.default.fileExists(atPath: t.stagingPath) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return t
    }

    private func setCreateResume(_ t: VaultGenerator.ResumeToken?) { createResume = t; Self.persistResume(t, Self.createResumeKey) }
    private func setUpdateResume(_ t: VaultGenerator.ResumeToken?) { updateResume = t; Self.persistResume(t, Self.updateResumeKey) }

    /// Persist (only a resumable token — a session id to reopen, or completed slices whose fold
    /// lives in staging) or clear the handle on disk.
    private static func persistResume(_ t: VaultGenerator.ResumeToken?, _ key: String) {
        if let t, t.sessionID != nil || (t.sliceIndex ?? 0) > 0, let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    enum CloudError: LocalizedError {
        case empty
        case noVault
        case usageLimit(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .empty:             return "No summaries yet; run the on-device pass first."
            case .noVault:           return "No knowledge base on disk yet; run \"go make knowledge base exist\" first."
            case .usageLimit(let m): return "Your AI hit its usage limit; try again later to resume. (\(m.prefix(160)))"
            case .failed(let m):     return m
            }
        }
    }

    // MARK: Create — "go make knowledge base exist" (DISABLED — pending phase-2 agent loop)

    @discardableResult
    func create(notes: [CloudNote],
                onProgress: @Sendable @escaping (VaultGenerator.Progress) -> Void = { _ in },
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> VaultGenerator.Result {
        // ponytail: phase-2 disabled — vault create/update needs an agent loop with file tools.
        // Restored when the Swift agent loop over OpenAI tool-calling lands.
        throw CloudError.failed("Knowledge-base creation needs the local-LLM agent loop (phase 2).")
    }

    // MARK: Update — "go update knowledge base" (DISABLED — pending phase-2 agent loop)

    /// Merge the current cycle's notes into the existing vault. Returns the number of notes sent.
    /// DISABLED in phase 1: codex's agentic file-editing loop has no local-LLM replacement yet.
    @discardableResult
    func update(notes: [CloudNote],
                onProgress: @Sendable @escaping (VaultGenerator.Progress) -> Void = { _ in },
                onLine: (@Sendable (String) -> Void)? = nil) async throws -> Int {
        throw CloudError.failed("Knowledge-base update needs the local-LLM agent loop (phase 2).")
    }

    // MARK: Mirror push

    /// Flag the vault as changed (so a later sync knows there's something to push) WITHOUT pushing.
    /// MCP sync is currently a SEPARATE manual step — the dev "MCP SYNC" button calls
    /// `MirrorClient.push()`, and `pushIfDirty()` runs on app launch as the catch-up. To restore
    /// auto-push-after-KB-update, just call `await Self.pushIfDirty()` here.
    private func markDirty() async {
        await MainActor.run { VaultActivity.shared.vaultDirty = true }
    }

    /// Push the vault to the mirror IFF the mirror is enabled AND there's an unsynced change
    /// (`VaultActivity.vaultDirty`). Clears the dirty flag only on a successful push; a failure
    /// leaves it set so the next trigger retries. Called after every create/update AND once on app
    /// launch (`SentientOSApp`) — that launch call is the durable catch-up for a push that failed
    /// or never ran (e.g. the app quit between a KB update and its push). No-op when the mirror is
    /// off or the vault is already in sync, so it's safe to call anytime.
    static func pushIfDirty() async {
        guard await MirrorClient.shared.isEnabled else { return }
        guard await MainActor.run(body: { VaultActivity.shared.vaultDirty }) else { return }
        do {
            try await MirrorClient.shared.push()
            await MainActor.run { VaultActivity.shared.vaultDirty = false }
            Log("VaultCloud: mirror pushed ✓")
        } catch {
            // §7.18: this swallows + retries forever, leaving the mirror stale (the user's AIs read
            // old data). Emit the HTTP status only — never the response body (MirrorError.http's 2nd
            // arg embeds it). Status 0 = no HTTP response (B4); "n/a" = a non-HTTP error (zip/network).
            var status = "n/a"
            if case MirrorClient.MirrorError.http(let code, _) = error { status = String(code) }
            CrashReporting.captureEvent("mirror.push_failed", level: .warning,
                tags: ["error": String(describing: type(of: error))],
                extra: ["http_status": status],
                fingerprint: ["mirror", "push_failed"])
            Log("VaultCloud: mirror push failed — \(ErrorLabel(error)) (retries next trigger)")
        }
    }

    // MARK: Prompts

    /// The vault's current shape — a recursive ls of .md paths (the tree IS the index).
    static func skeleton(of root: URL) -> String {
        (((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") && !$0.contains("/.") }
            .sorted()).joined(separator: "\n")
    }

    /// The editing-flavored Stage-2 prompt — lifted verbatim from the old VaultUpdater
    /// (eval-validated), fed CloudNotes. Surgical edits, not a rebuild. Internal (not private):
    /// a sliced first build reuses it verbatim for slices 1+ — folding a batch into the staged
    /// vault is the same job as folding a night into the live one.
    static func updatePrompt(skeleton: String, notes: [CloudNote]) -> String {
        let df = CorpusSlicer.dateFormatter()
        let lines = notes.enumerated().map { i, n in CorpusSlicer.render(n, index: i, df: df) }

        return """
        You are the **Sentient OS Knowledge Base Architect** — the cloud brain of a privacy-first \
        personal-intelligence product. You previously organized this user's digital life into the \
        Obsidian-style markdown vault that is your current working directory. While their Mac sat \
        idle, an on-device LLM privately summarized the user's NEW items — you are receiving today's \
        survivors (junk and sensitive items were already discarded on-device). Your job: merge them \
        into the existing vault, surgically.

        ## The vault's current skeleton (a recursive ls — the tree IS the index)
        \(skeleton)

        ## How to work — surgical edits, not a rebuild
        - **You are the second sieve — not every item deserves the vault.** The on-device model \
        already dropped obvious junk, but it is a small, lenient model; YOU are the quality bar, \
        exactly as when you built this vault (curate ruthlessly). Change the vault ONLY where an \
        item genuinely makes the knowledge base more VALUABLE. If an item adds nothing durable — \
        trivia, noise, redundancy an existing note already covers — SKIP it: change nothing for that \
        item. A run where nothing is worth merging is a perfectly good run; reply "0".
        - **Explore only the notes you need.** Search the tree to find where each new item belongs; \
        do not re-read the whole vault.
        - **Consolidate, hard — as much as possible, fold new items into EXISTING notes.** For \
        roughly 90% of worthwhile items the right move is editing the info into a relevant EXISTING \
        note; creating a NEW note (or, very rarely, a new folder) is right in maybe ~5% of cases — \
        only when something TRULY deserves its own file and belongs nowhere that already exists. \
        NEVER default to spawning a new note for a small piece of new info — a sprawl of tiny new \
        notes is exactly what we're avoiding: after six months of nightly merges this vault must \
        still be tight and navigable, not a mess of files. When you DO create one, follow the \
        existing folder structure and naming style (`Domain/Specific — Topic.md`, no frontmatter — \
        open with the `# Title` H1).
        - **Preserve the vault's tight shape.** A healthy vault stays compact: at most ~10 root \
        folders, a few subfolders per domain, a handful (~2–5) of substantial notes per subfolder. \
        If a merge would push a folder past that shape, fold the info into an existing note instead \
        of adding a file — the vault should grow in KNOWLEDGE, not in file count.
        - **Never delete notes wholesale**, never reorganize folders, never rename existing notes \
        (links point at them). Keep every `[[wikilink]]` intact; add new ones where a new item \
        genuinely connects.
        - **Synthesize, don't append-dump.** Work an item into the narrative of its note — update \
        facts, extend timelines, collapse redundancy.
        - **Never use em dashes (—) in the note text you write.** Use a semicolon, colon, comma, or \
        period instead.
        - If today's items genuinely change who the user is or what they're up to, update the root \
        `README.md` portrait — otherwise leave it untouched.

        ## ⚠️ TRUTH & ATTRIBUTION — the most important rule (unchanged from your first build)
        Other AIs will state these facts back to people as truth; a confident false claim is worse \
        than an omission. The `[source]` tag tells you how much to trust each item: the user's own \
        authored notes (Obsidian / user-authored / Apple Notes) are genuinely theirs; screenshots \
        and saved files are often about OTHER people, products, or topics — never absorb someone \
        else's biography, job, or project into the user. When ambiguous, omit or phrase literally \
        ("saved a screenshot of X") rather than "is/did X". Never include raw private specifics \
        (card/account numbers, passwords, exact medical or financial figures).

        ## Today's new items (each: `#index · [source] location · item date`, then `Title — summary`)

        \(lines.joined(separator: "\n\n"))

        Merge them in now. When you are done, reply with ONE line: the number of notes you created \
        or edited.
        """
    }

}
