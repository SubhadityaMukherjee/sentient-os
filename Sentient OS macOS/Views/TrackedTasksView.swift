//
//  TrackedTasksView.swift
//  Sentient OS macOS
//
//  The management window for the user's Tracked Tasks — the round-tripped markdown file at the
//  vault root that the proactive judge and research stages read to filter their suggestions.
//  Surfaced from the home's Analysis popover.
//
//  Browse by status (Open / On Hold / Closed), add a new task, move a task between statuses, or
//  remove it entirely. Every mutation funnels through `TaskTracker`, which regenerates the file
//  on disk. The file is the source of truth — reopen the window after a hand-edit and you'll see
//  your changes (the parser is loose; missing ids get regenerated, missing dates default to now).
//

import SwiftUI

struct TrackedTasksView: View {
    @State private var tasks: [TrackedTask] = []
    @State private var newTitle: String = ""
    @State private var newStatus: TrackedTask.Status = .open
    @State private var newNote: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Ink.deepMuted.opacity(0.4))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    addRow
                    ForEach(TrackedTask.Status.allCases, id: \.self) { status in
                        section(status)
                    }
                    if tasks.isEmpty {
                        emptyState
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 560)
        .background(Color.black)
        .task { await refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tracked Tasks").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                Text("Open · On Hold · Closed — Sentient's proactive judge reads this to filter suggestions.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
            Spacer(minLength: 0)
            if !tasks.isEmpty {
                Text("\(tasks.count) tracked").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Ink.label)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoCaps("Add a task", size: 9.5, tracking: 2.0, color: Theme.Ink.label)
            HStack(spacing: 8) {
                TextField("Title (e.g. Reply to Dana about Q3 plan)", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { Task { await commitNew() } }
                Picker("", selection: $newStatus) {
                    ForEach(TrackedTask.Status.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button(action: { Task { await commitNew() } }) {
                    Text("Add").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? AnyShapeStyle(Color.white.opacity(0.06))
                                    : AnyShapeStyle(Color.white.opacity(0.14)),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Optional note (e.g. waiting on documents, done yesterday)", text: $newNote)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Ink.body)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Status sections

    @ViewBuilder
    private func section(_ status: TrackedTask.Status) -> some View {
        let group = tasks.filter { $0.status == status }.sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor(status)).frame(width: 6, height: 6)
                MonoCaps(status.label.uppercased(), size: 10, tracking: 2.2, color: Theme.Ink.label)
                Text("\(group.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.Ink.deepMuted)
            }
            if group.isEmpty {
                Text("(none)").font(.system(size: 11)).italic().foregroundStyle(Theme.Ink.deepMuted)
                    .padding(.leading, 14)
            } else {
                ForEach(group) { task in
                    taskRow(task)
                }
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TrackedTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(task.status == .closed ? Theme.Ink.bright.opacity(0.55) : .white)
                    .strikethrough(task.status == .closed, color: Theme.Ink.deepMuted)
                if !task.note.isEmpty {
                    Text(task.note).font(.system(size: 10.5)).foregroundStyle(Theme.Ink.body)
                }
            }
            Spacer(minLength: 0)
            // Status switcher — the quick move between sections.
            Menu {
                ForEach(TrackedTask.Status.allCases, id: \.self) { s in
                    Button(s.label) {
                        Task { await move(task, to: s) }
                    }.disabled(s == task.status)
                }
                Divider()
                Button("Remove", role: .destructive) {
                    Task { await remove(task) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.leading, 14).padding(.trailing, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing tracked yet")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text("Add a task above, or click ✓ on a card the AI suggests to mark it done.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    // MARK: Actions

    private func commitNew() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        await TaskTracker.shared.add(title: title, status: newStatus, note: note, date: Date())
        newTitle = ""
        newNote = ""
        await refresh()
    }

    private func move(_ task: TrackedTask, to status: TrackedTask.Status) async {
        await TaskTracker.shared.setStatus(id: task.id, to: status)
        await refresh()
    }

    private func remove(_ task: TrackedTask) async {
        await TaskTracker.shared.remove(id: task.id)
        await refresh()
    }

    private func refresh() async {
        await TaskTracker.shared.ensureExists()
        tasks = await TaskTracker.shared.readAll()
    }

    private func dotColor(_ status: TrackedTask.Status) -> Color {
        switch status {
        case .open:   return Theme.Ink.green
        case .onHold: return Theme.Ink.amber
        case .closed: return Theme.Ink.deepMuted
        }
    }
}
