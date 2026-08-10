//
//  ProactivePane.swift
//  Sentient OS macOS
//
//  Settings → Proactive & Sidekick: the user's standing instructions for the proactive
//  suggestion writer, Sidekick's shortcut key + standing context. The strings persist and
//  autosave. The hotkey choice (right ⌘ / right ⌥) is LIVE — toggling it posts
//  `.sidekickHotkeyChanged`, which re-keys the running SidekickHotkeyMonitor with no restart. The
//  two text fields are LIVE too: `proactive.instructions` feeds the proactive prompts
//  (Proactive.instructionsBlock, PART 1 + 2) and `sidekick.context` feeds the command/Sidekick
//  prompt (CommandRunModel.commandPrompt) — the two keys live in CustomInstructions so producer
//  and consumers can't drift.
//
//  ponytail: phase-2 — was the Speed-vs-Intelligence slider (ComputerUseSpeed, codex-only). The
//  new local-LLM agent loop will bring its own knob when it lands; until then this pane is just
//  instructions + the hotkey/context.
//

import SwiftUI

struct ProactivePane: View {
    @AppStorage(CustomInstructions.proactiveKey) private var proactiveInstructions = ""
    @AppStorage("sidekick.hotkey") private var sidekickHotkey = "rightCommand"
    @AppStorage(CustomInstructions.sidekickKey) private var sidekickContext = ""
    @AppStorage(RealtimeScheduler.enabledKey) private var realtimeEnabled = false
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPane(title: "Proactive & Sidekick",
                     whisper: "Morning suggestions, and the hold-to-talk magic in your notch.") {
            VStack(alignment: .leading, spacing: 30) {
                SettingsGroup(label: "Proactive Intelligence") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsProse("Every morning, Sentient surfaces a few things worth doing, already done and waiting for your go. Tell it what you care about, and what to skip.")
                        SettingsTextBox(placeholder: "e.g. Don't give me suggestions about Chase Bank alerts.",
                                        text: $proactiveInstructions)
                    }
                }
                SettingsHairline(opacity: 0.12)
                    .padding(.vertical, -7)   // sit tighter than the pane's 30pt group rhythm
                SettingsGroup(label: "Real-time recommendations") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $realtimeEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Surface urgent things through the day").font(.callout)
                                Text("While Sentient is open, check for new mail, files, and messages about every 20 minutes. High-urgency items appear as cards immediately, instead of waiting for tomorrow morning.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: realtimeEnabled) { _, _ in appState.realtimeScheduler.reevaluate() }
                        if !LocalLLMConfig.isConfigured {
                            Text("Configure a local LLM endpoint in Settings → Permissions & Health to enable real-time recommendations.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                SettingsHairline(opacity: 0.12)
                    .padding(.vertical, -7)   // sit tighter than the pane's 30pt group rhythm
                SettingsGroup(label: "Sidekick") {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsProse("Hold the shortcut key and just talk (\u{201C}finish this for me\u{201D}), and Sidekick acts on whatever you're looking at.")
                        ChipFlow {
                            SettingsChip(label: "Right ⌘", on: sidekickHotkey == "rightCommand") {
                                sidekickHotkey = "rightCommand"
                            }
                            SettingsChip(label: "Right ⌥", on: sidekickHotkey == "rightOption") {
                                sidekickHotkey = "rightOption"
                            }
                        }
                        .onChange(of: sidekickHotkey) {
                            // Re-key the live monitor immediately — no restart.
                            NotificationCenter.default.post(name: .sidekickHotkeyChanged, object: nil)
                        }
                        SettingsTextBox(placeholder: "e.g. When I say text someone, use WhatsApp. My main browser is Microsoft Edge.",
                                        text: $sidekickContext)
                    }
                }
            }
        }
    }
}

#Preview("Proactive & Sidekick pane") {
    ProactivePane()
        .background(Theme.bg)
        .frame(width: 720, height: 760)
}
