//
//  PermissionsView.swift
//  Sentient OS macOS
//
//  Dev-tools PERMISSIONS panel (a sheet behind DEV TOOLS → PERMISSIONS). A home for every macOS
//  privacy grant Sentient asks for, in two groups:
//
//  SENTIENT — Full Disk Access (read the DB sources) · Microphone+Speech (hold right-⌘ to speak) ·
//    Screen Recording (Notch Magic captures the screen so computer use has on-screen context) ·
//    Automation (drive Codex's helper) · the overnight wake daemon (root, for the 3am wake).
//  CODEX COMPUTER USE — the helper's Accessibility (move mouse / type) + Screen Recording (see the
//    screen). These belong to Codex's helper app, not Sentient.
//
//  The Automation grant is written straight into the user's TCC database using the Full Disk
//  Access Sentient already holds (device-/signer-agnostic — the code-requirement blobs are made
//  from the live apps). The two Codex grants (Accessibility + Screen Recording) live in the
//  SIP-protected SYSTEM TCC db — no app can write those, so their panes are STATUS-ONLY (read via
//  FDA) + a Settings deep-link. Mic uses the normal request API; screen recording uses
//  CGRequestScreenCapture; the daemon uses SMAppService. Every pane also has a re-check.
//

import SwiftUI
import ServiceManagement   // SMAppService.Status — the wake daemon's registration state

struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss

    // Sentient's own grants
    @State private var fdaGranted = false
    @State private var micGranted = false
    @State private var srGranted = false          // Sentient's Screen Recording
    @State private var automationGranted = false   // Sentient → Apple Events (user DB)
    @State private var automationStatus: String?
    @State private var daemonReady = false
    @State private var daemonStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PERMISSIONS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    sectionHeader("SENTIENT")
                    fdaPane
                    micPane
                    screenRecordingPane
                    automationPane
                    wakeDaemonPane
                }
                .padding(24)
            }
        }
        .frame(width: 580, height: 560)
        .background(Theme.bg)
        .onAppear(perform: refreshAll)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.secondary)
            Spacer()
        }
    }

    /// Re-read every live status. Cheap; called on appear and after each grant/re-check.
    private func refreshAll() {
        fdaGranted = Permissions.hasFullDiskAccess()
        micGranted = VoiceCapture.isAuthorized
        srGranted = Permissions.hasScreenRecording()
        automationGranted = Permissions.isTCCGranted(service: "kTCCServiceAppleEvents",
                                                     clientBundleID: Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS")
        daemonReady = WakeHelperClient.shared.isReady
    }

    // MARK: - Shared pane chrome

    /// Icon + title + GRANTED/NEEDED badge, a description, a row of action buttons, and an optional
    /// monospace receipt line. Used by every pane except the bespoke Automation one (long copy + revoke).
    @ViewBuilder
    private func pane(icon: String, iconColor: Color, title: String, granted: Bool,
                      description: String, receipt: String? = nil,
                      @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconColor)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(granted ? "GRANTED" : "NEEDED").font(.caption2.weight(.bold))
                    .foregroundStyle(granted ? Theme.verdictColor(.survivor) : .orange)
            }
            Text(description).font(.caption2).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions() }
            if let receipt { receiptLine(receipt) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private func receiptLine(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(text.hasPrefix("✓") ? Theme.Ink.green : text.hasPrefix("✗") ? .red : Theme.secondary)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - SENTIENT panes

    private var fdaPane: some View {
        pane(icon: fdaGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
             iconColor: fdaGranted ? Theme.verdictColor(.survivor) : .orange,
             title: "Full Disk Access", granted: fdaGranted,
             description: "Lets the WhatsApp · iMessage · Apple Notes sources read their protected databases. Changing it needs an app restart.") {
            Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.bordered).tint(Theme.accent)
            Button("Restart app") { Permissions.relaunch() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var micPane: some View {
        pane(icon: "mic.fill", iconColor: micGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Microphone & Speech", granted: micGranted,
             description: "Lets you hold the right Command key and speak the task you want done — Sentient transcribes it on-device.") {
            Button("Grant microphone…") {
                Task {
                    // First ask surfaces the system prompt; if it's already denied/restricted there's no
                    // prompt to show, so fall back to Settings rather than silently doing nothing.
                    let ok = await VoiceCapture.requestPermissions()
                    if !ok { Permissions.openMicrophoneSettings() }
                    refreshAll()
                }
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var screenRecordingPane: some View {
        pane(icon: "rectangle.dashed.badge.record", iconColor: srGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Screen Recording", granted: srGranted,
             description: "When you summon the command bar, Sentient captures the current screen so computer use knows what you're looking at. Takes effect after an app restart.") {
            Button("Grant screen recording…") { _ = Permissions.requestScreenRecording(); refreshAll() }
                .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Screen Recording Settings") { Permissions.openScreenRecordingSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Restart app") { Permissions.relaunch() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    /// Automation — Sentient's right to drive other apps over Apple Events. (phase-1: just reads
    /// the user TCC entry; phase-2 restores the grant helper for the AX-API computer-use agent.)
    private var automationPane: some View {
        pane(icon: "desktopcomputer", iconColor: automationGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Automation — Apple Events", granted: automationGranted,
             description: "Sentient's right to drive other Mac apps over Apple Events. Read-only here for now; the local-LLM agent loop's computer-use work will reuse this grant.",
             receipt: automationStatus) {
            Button("Open Automation Settings") { Permissions.openAutomationSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var wakeDaemonPane: some View {
        pane(icon: "moon.zzz.fill", iconColor: daemonReady ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Overnight wake daemon (root)", granted: daemonReady,
             description: "Sentient's 3am wake needs a tiny root helper to hold the Mac awake (lid shut) while it processes. macOS asks you to approve it once under Login Items — an approval toggle, not a typed password.",
             receipt: daemonStatus) {
            Button("Install / register daemon") {
                let st = WakeHelperClient.shared.register()
                daemonStatus = "status: \(st.rawValue) (\(daemonStatusName(st)))"
                if st == .requiresApproval { WakeHelperClient.shared.openLoginItemsSettings() }
                refreshAll()
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Login Items") { WakeHelperClient.shared.openLoginItemsSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private func daemonStatusName(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          return "enabled"
        case .requiresApproval: return "needs approval in Login Items"
        case .notRegistered:    return "not registered"
        case .notFound:         return "not found (unsigned build?)"
        @unknown default:       return "unknown"
        }
    }
}

#Preview("Permissions") {
    PermissionsView().preferredColorScheme(.dark)
}
