//
//  HealthPane.swift
//  Sentient OS macOS
//
//  Settings → Permissions & Health: the health board. Live LED rows for every grant Sentient
//  actually asks for, in severity order — SENTIENT (Full Disk Access · the overnight wake daemon ·
//  launch-at-login · mic & speech · notifications), SET UP CODEX (CLI · account · ChatGPT plan
//  via CodexAuth · computer use, via the shared CodexSetup engine), and CODEX PERMISSIONS (the
//  helper's Accessibility + Screen
//  Recording — system-TCC, status-only, shown once computer use exists). The Automation grant has
//  NO row: it self-heals silently shortly after the pane opens (the user has no job there).
//  Red = a core capability is broken · yellow = optional, fixable-later, or working on it. The
//  codex fix buttons drive the shared engine INLINE (install / browser login with auto-notice /
//  computer-use bootstrap — no sheet; CodexSetupView is dev-tools-only now). When the whole codex
//  stack is green it collapses to one glowing summary line (tap for details) — a browsing user
//  shouldn't wade through five rows of "fine". Statuses re-probe on app foreground.
//  (Reset lives in Settings → System.)
//

import SwiftUI
import AppKit
import AVFoundation
import Speech
import UserNotifications

struct HealthPane: View {
    /// Optional on purpose: the pane's #Preview renders without an AppState in the environment.
    @Environment(AppState.self) private var appState: AppState?

    // Sentient's own grants
    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var daemon: DaemonState = .notSetUp
    @State private var loginOn = LoginItem.isEnabled
    @State private var micSpeech: MicSpeechState = .notAsked
    @State private var screenRec = Permissions.hasScreenRecording()   // Sentient's own grant — Sidekick's screen context
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    // Local LLM endpoint config (the new "is the brain connected?" surface)
    @State private var endpointConfig: LocalLLMConfig = LocalLLMConfig.current()
    @State private var endpointTesting = false
    @State private var endpointTestResult: String? = nil
    @State private var endpointTestOK = false
    @State private var endpointExpanded = true

    @State private var checked = false        // first full probe done
    @State private var revealed = false       // drives the rise-in cascade after the first probe

    private enum DaemonState { case ready, installing, notSetUp, disabled }
    private enum MicSpeechState { case granted, notAsked, denied }

    /// True when the endpoint has been configured AND verified to answer.
    private var endpointAllGreen: Bool { endpointConfig.isConfigured }

    private var allGreen: Bool {
        fdaGranted && daemon == .ready && loginOn && micSpeech == .granted && screenRec
            && (notifStatus == .authorized || notifStatus == .provisional)
            && endpointAllGreen
    }

    var body: some View {
        SettingsPane(title: "Permissions & Health",
                     whisper: allGreen ? "All clear. Your Sentient is healthy."
                                       : "Everything green means everything works.") {
            if !checked {
                checkingLine
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    onDeviceGroup
                    sidekickGroup
                    SettingsHairline(opacity: 0.12)
                        .padding(.vertical, -7)   // the brighter, tighter group splitter (matches ProactivePane's)
                        .rise(6, revealed: revealed)
                    Group {
                        if endpointAllGreen && !endpointExpanded {
                            SettingsGroup(label: "Local LLM") { endpointSummaryLine }
                        } else {
                            endpointGroup
                        }
                    }
                    .rise(7, revealed: revealed)
                }
                .task { revealed = true }
            }
        }
        .task {
            await refresh()
            try? await Task.sleep(for: .seconds(0.5))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }   // the user may just have fixed something in System Settings
        }
    }

    // MARK: - SENTIENT (severity order)

    /// The first probe's stand-in — the codex login check shells out and takes seconds; without
    /// this the full board flashes and re-collapses.
    private var checkingLine: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking your Sentient…")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.body)
        }
        .padding(.top, 10)
    }

    private var onDeviceGroup: some View {
        SettingsGroup(label: "On-device Intelligence") {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLine(title: "Full Disk Access",
                               health: fdaGranted ? .ok : .bad,
                               note: fdaGranted ? "granted" : "not granted",
                               tip: "Lets Sentient's on-device LLM read your files & folders, and the databases WhatsApp, iMessage, and Notes keep on this Mac.\n\nEverything is read right here on your Mac; your data never leaves it.",
                               fixTitle: "Grant…") {
                        PermissionGuide.shared.guide(.fullDiskAccess, dragging: Bundle.main.bundleURL)
                    }
                    if !fdaGranted {
                        HStack(spacing: 6) {
                            SettingsProse("WhatsApp, iMessage & Notes stay unreadable without it. After granting:")
                            Button { Permissions.relaunch() } label: {
                                Text("Relaunch Sentient")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.Ink.bright)
                                    .underline(true, color: Theme.Ink.deepMuted)
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                        .padding(.bottom, 6)
                    }
                }
                .rise(0, revealed: revealed)
                StatusLine(title: "Overnight wake",
                           health: daemon == .ready ? .ok : .bad,
                           note: daemonNote,
                           tip: "A tiny system helper that wakes your Mac at 3 AM so Sentient's on-device intelligence can work while you sleep.\n\nIt only runs while your Mac is plugged in and Sentient is open in your menu bar. Installed once with your password.",
                           fixTitle: daemon == .disabled ? "Turn On…" : "Set Up…") {
                    fixDaemon()
                }
                .rise(1, revealed: revealed)
                StatusLine(title: "Launch at login",
                           health: loginOn ? .ok : .warn,
                           note: loginOn ? "on" : (LoginItem.needsApproval ? "approve in system settings" : "off"),
                           tip: "Starts Sentient quietly in your menu bar when you log in, so the overnight run can happen and your Sentient can stay alive.",
                           fixTitle: LoginItem.needsApproval ? "Approve…" : "Turn On") {
                    LoginItem.enableOrRequestApproval()
                    loginOn = LoginItem.isEnabled
                    if LoginItem.needsApproval {
                        PermissionGuide.shared.guide(.loginItems, dragging: nil)
                    }
                }
                .rise(2, revealed: revealed)
            }
        }
    }

    private var sidekickGroup: some View {
        SettingsGroup(label: "Sidekick & Proactive") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Microphone & Speech",
                           health: micSpeech == .granted ? .ok : .warn,   // optional — Sidekick's voice; tap-to-type works without it
                           note: micSpeechNote,
                           tip: "Optional but recommended.\nLets Sidekick hear you and turn your words into text when you hold the shortcut key.\n\nWithout it, hold-to-talk stays off — you can still tap the key (or click the notch) and type.\n\nYour voice is heard and transcribed on this Mac, never in the cloud.",
                           fixTitle: micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
                .rise(3, revealed: revealed)
                StatusLine(title: "Screen Recording",
                           health: screenRec ? .ok : .warn,   // optional — Sidekick runs text-only without it
                           note: screenRec ? "granted" : "optional",
                           tip: "Optional but recommended.\nLets Sidekick see a screenshot of your screen the moment you summon it, so it can see the thing you're asking about (\u{201C}finish this\u{201D}, \u{201C}reply to this\u{201D}).\n\nWithout it, you'll have to explicitly tell Sidekick which app you want it to start controlling.",
                           fixTitle: "Allow…") {
                    fixScreenRecording()
                }
                .rise(4, revealed: revealed)
                StatusLine(title: "Notifications",
                           health: notifHealth,
                           note: notifNote,
                           tip: "Lets Sentient send a morning note when new suggestions are ready. Optional; everything works without it.",
                           fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
                    fixNotifications()
                }
                .rise(5, revealed: revealed)
            }
        }
    }

    // MARK: Overnight wake daemon

    private var daemonNote: String {
        switch daemon {
        case .ready:      return "ready"
        case .installing: return "installing…"
        case .notSetUp:   return "not set up"
        case .disabled:   return "turned off in login items"
        }
    }

    /// [DECIDED 2026-07-04] The password install IS the production path (no Login Items
    /// migration — one native admin prompt, no trip to System Settings). Fix = run the installer —
    /// EXCEPT when the daemon is installed but toggled off in System Settings: launchd honors that
    /// switch over any bootstrap, so the only fix is the user flipping it back on.
    private func fixDaemon() {
        switch daemon {
        case .ready, .installing:
            return
        case .disabled:
            WakeHelperClient.shared.openLoginItemsSettings()
        case .notSetUp:
            daemon = .installing
            Task {
                _ = await WakeHelperInstaller.installAsync()
                try? await Task.sleep(for: .seconds(1))   // let launchd settle before the XPC probe
                await refreshDaemon()
                // A fresh install may be the last missing prerequisite — re-run the 14h check now
                // instead of waiting for the next launch (this app rarely relaunches).
                if daemon == .ready { appState?.scheduler.maybeAutoEnable() }
            }
        }
    }

    /// Green = the daemon ANSWERS over XPC (the only check the System Settings background toggle
    /// can't fool) — WakeHelperClient.healthProbe is the shared verdict.
    private func refreshDaemon() async {
        switch await WakeHelperClient.shared.healthProbe() {
        case .ready:    daemon = .ready
        case .disabled: daemon = .disabled
        case .notSetUp: daemon = .notSetUp
        }
    }

    // MARK: Microphone & Speech (one row — one call asks for both; optional, so yellow, never red)

    private var micSpeechNote: String {
        switch micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "not asked yet"
        case .denied:   return "off"
        }
    }

    private func fixMicSpeech() {
        switch micSpeech {
        case .granted:
            break
        case .notAsked:
            Task { _ = await VoiceCapture.requestPermissions(); await refresh() }
        case .denied:
            // Deep-link to whichever grant is actually the blocker (mic first — it gates speech).
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.openSpeechRecognitionSettings()
            }
        }
    }

    // MARK: Screen Recording (Sentient's own grant — Sidekick's screen context)

    /// The Screen Recording list is drag-authorizable, and Sentient may not be IN the list at all
    /// (on Tahoe, CGRequestScreenCaptureAccess doesn't reliably add it — field-verified), so the
    /// guide always carries Sentient itself as the drag card. Harmless when the row already
    /// exists; the user just flips the existing switch.
    private func fixScreenRecording() {
        guard !screenRec else { return }
        PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
    }

    private func refreshMicSpeech() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .authorized && speech == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
    }

    // MARK: Notifications (yellow when off, never red — the morning briefing sleeps, the app works)

    private var notifHealth: StatusLine.Health {
        switch notifStatus {
        case .authorized, .provisional: return .ok
        default:                        return .warn
        }
    }

    private var notifNote: String {
        switch notifStatus {
        case .authorized:    return "on"
        case .provisional:   return "quiet"   // the launch-banked provisional grant (no banners/sounds)
        case .notDetermined: return "not asked yet"
        default:             return "off"
        }
    }

    private func fixNotifications() {
        if notifStatus == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refresh()
            }
        } else {
            // Modern Settings pane first (Ventura+), legacy anchor as fallback — same pattern as
            // Permissions.openFullDiskAccessSettings.
            let modern = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            let legacy = "x-apple.systempreferences:com.apple.preference.notifications"
            if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
            if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - LOCAL LLM ENDPOINT (the brain — base URL, model, optional API key)

    /// The collapsible "all good" summary line, shown when the endpoint is configured.
    private var endpointSummaryLine: some View {
        Button { withAnimation { endpointExpanded = true } } label: {
            HStack(spacing: 11) {
                HealthDot(color: Theme.Ink.green)
                Text("Local LLM is connected.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                Spacer(minLength: 12)
                Text(endpointConfig.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Ink.label)
                MonoCaps("Details", size: 8.5, tracking: 1.6, color: Theme.Ink.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The editable group: base URL, model, API key, Test button, status line.
    private var endpointGroup: some View {
        SettingsGroup(label: "Local LLM Endpoint") {
            VStack(alignment: .leading, spacing: 10) {
                endpointField(label: "Base URL", placeholder: "http://localhost:11434/v1",
                              text: Binding(get: { endpointConfig.baseURL },
                                            set: { endpointConfig = LocalLLMConfig(baseURL: $0, apiKey: endpointConfig.apiKey, model: endpointConfig.model) }))
                endpointField(label: "Model", placeholder: "llama3.2",
                              text: Binding(get: { endpointConfig.model },
                                            set: { endpointConfig = LocalLLMConfig(baseURL: endpointConfig.baseURL, apiKey: endpointConfig.apiKey, model: $0) }))
                endpointField(label: "API key", placeholder: "optional (blank for local servers)",
                              text: Binding(get: { endpointConfig.apiKey },
                                            set: { endpointConfig = LocalLLMConfig(baseURL: endpointConfig.baseURL, apiKey: $0, model: endpointConfig.model) }))

                HStack(spacing: 10) {
                    Button {
                        Task { await testEndpoint() }
                    } label: {
                        HStack(spacing: 7) {
                            if endpointTesting { ProgressView().controlSize(.mini) }
                            Text(endpointTesting ? "testing…" : "Test connection")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.Ink.body)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(endpointTesting || !endpointConfig.isConfigured)

                    if endpointAllGreen {
                        Button {
                            withAnimation { endpointExpanded = false }
                        } label: {
                            Text("Collapse")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.Ink.label)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }

                if let endpointTestResult {
                    Text(endpointTestResult)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(endpointTestOK ? Theme.Ink.green : .red)
                }

                SettingsProse("Any OpenAI-compatible endpoint works: Ollama, LM Studio, llama.cpp server, vLLM, MLX server, etc. Sentient never sends your data anywhere except the endpoint you configure.")
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func endpointField(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.Ink.body)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func testEndpoint() async {
        endpointTesting = true
        endpointTestResult = nil
        LocalLLMConfig.save(baseURL: endpointConfig.baseURL,
                            apiKey: endpointConfig.apiKey,
                            model: endpointConfig.model)
        await LocalLLM.shared.reloadConfig()
        let err = await LocalLLM.shared.ping()
        endpointTesting = false
        if let err {
            endpointTestOK = false
            endpointTestResult = "✗ \(err.prefix(160))"
        } else {
            endpointTestOK = true
            endpointTestResult = "✓ connected — \(endpointConfig.model) answered"
        }
    }

    // MARK: - Probes

    private func refresh() async {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        await refreshDaemon()
        refreshMicSpeech()
        screenRec = Permissions.hasScreenRecording()
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        endpointConfig = LocalLLMConfig.current()   // pick up any external change
        withAnimation(.easeOut(duration: 0.2)) { checked = true }   // first probe done → reveal
    }
}

/// The gentle rise-in: each element starts a touch lower and transparent, then swoops up into
/// place with a small stagger — subtle, physics-flavored, over in under half a second.
private extension View {
    func rise(_ index: Int, revealed: Bool) -> some View {
        self.opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 14)
            .animation(.spring(response: 0.45, dampingFraction: 0.85)
                .delay(Double(index) * 0.055), value: revealed)
    }
}

#Preview("Permissions & Health pane") {
    HealthPane()
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
