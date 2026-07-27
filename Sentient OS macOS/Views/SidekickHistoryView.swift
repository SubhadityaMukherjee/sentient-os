//
//  SidekickHistoryView.swift
//  Sentient OS macOS
//
//  The "what Sidekick did for me" window — a newest-first list of completed Sidekick runs, each with
//  the ask, the outcome, the agent's one-line summary (or the reason it couldn't), how long it ran,
//  and when. Reached from the menu-bar item or by tapping the completion notification. The list reads
//  from SidekickHistoryStore (its own on-disk SwiftData store); a refresh on appear picks up a run
//  that just finished when the notification opens the window.
//

import SwiftUI

struct SidekickHistoryView: View {
    /// Scene id for the standalone history window (opened via `openWindow`, from the menu bar or a
    /// notification tap).
    static let windowID = "sidekick-history"

    @State private var items: [SidekickRunItem] = []
    @State private var loaded = false
    @State private var showClearConfirm = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await load() }
        .confirmationDialog("Clear all Sidekick history?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await SidekickHistoryStore.shared.clearAll(); await load() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView().tint(Theme.faint)
        } else if items.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No Sidekick history yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.faint)
            Text("Runs you ask Sidekick to do will show up here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sidekick History")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showClearConfirm = true
                } label: {
                    Text("Clear")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 6)
            }
        }
    }

    private func row(_ item: SidekickRunItem) -> some View {
        let glyph = Glyph.forOutcome(item.outcome)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(glyph.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(glyph.color)
                Text(item.command)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(item.completedAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint.opacity(0.95))
                    .lineLimit(3)
                    .padding(.leading, 24)
            }
            Text(meta(for: item))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint.opacity(0.7))
                .padding(.leading, 24)
        }
        .padding(.vertical, 12)
    }

    private func meta(for item: SidekickRunItem) -> String {
        let dur = durationLabel(item.durationSeconds)
        let sourceLabel = item.source.isEmpty ? "" : " · \(item.source)"
        return "\(dur)\(sourceLabel)"
    }

    private func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    @MainActor
    private func load() async {
        items = await SidekickHistoryStore.shared.recent()
        loaded = true
    }

    private struct Glyph {
        let symbol: String
        let color: Color
        static func forOutcome(_ o: SidekickOutcome) -> Glyph {
            switch o {
            case .success: Glyph(symbol: "✓", color: Theme.accent)
            case .failed:  Glyph(symbol: "✗", color: .red.opacity(0.85))
            case .stopped: Glyph(symbol: "■", color: Theme.faint)
            }
        }
    }
}
