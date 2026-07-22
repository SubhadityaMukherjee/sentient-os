//
//  ComputerUseGateView.swift
//  Sentient OS macOS
//
//  The one-time setup window's face (ComputerUseGate presents it): the action grants as the same
//  StatusLine rows Settings → Health uses, in two groups — SIDEKICK & PROACTIVE (Sentient's
//  OPTIONAL Microphone & Speech — amber, never blocking) and ACT ON YOUR MAC (Sentient's REQUIRED
//  Accessibility + Screen Recording — the gate holds the action until both are green).
//
//  ponytail: phase-3 — was the codex helper's TCC grants; now Sentient itself drives the Mac,
//  so both REQUIRED rows point at Sentient's own bundle in the system TCC lists.
//

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper("ONE-TIME SETUP")
                .frame(maxWidth: .infinity)

            Text("Give Sentient its hands and eyes.")
                .display(23)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            Text("Acting on your Mac needs these grants, once. You will not be asked again.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 26) {
                SettingsGroup(label: "Sidekick & Proactive") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Microphone & Speech",
                                   health: gate.micSpeech == .granted ? .ok : .warn,   // optional — amber, never blocking
                                   note: micSpeechNote,
                                   tip: "Optional but recommended.\nLets Sidekick hear you and turn your words into text when you hold the shortcut key.\n\nWithout it, hold-to-talk stays off — you can still tap the key (or click the notch) and type.\n\nYour voice is heard and transcribed on this Mac, never in the cloud.",
                                   fixTitle: gate.micSpeech == .notAsked ? "Allow…" : "Fix…") {
                            fixMicSpeech()
                        }
                    }
                }

                SettingsGroup(label: "Act On Your Mac") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Accessibility (move the mouse, type)",
                                   health: gate.sentientAccessibility ? .ok : .bad,
                                   note: gate.sentientAccessibility ? "granted" : "required",
                                   tip: "Lets Sentient itself move the mouse and type for you when you fire a computer-use action. Granted to Sentient (NOT a separate helper).",
                                   fixTitle: "Grant…") {
                            fixSentientAccessibility()
                        }
                        StatusLine(title: "Screen Recording (see the screen)",
                                   health: gate.sentientScreen ? .ok : .bad,
                                   note: gate.sentientScreen ? "granted" : "required",
                                   tip: "Lets Sentient see a screenshot of your screen so the agent acts on what you actually see. Granted to Sentient itself.",
                                   fixTitle: "Grant…") {
                            fixSentientScreen()
                        }
                    }
                }
            }
            .padding(.top, 30)

            // No bypass: while any required grant is red the button is disabled and says so, so a
            // feature can never be fired half-granted. It enables the instant every row goes green
            // (the rows re-probe on foreground + after the mic prompt).
            OnboardingNextButton(title: gate.allRequiredGranted ? "Continue" : "Grant permissions to continue",
                                 enabled: gate.allRequiredGranted) {
                gate.continueNow()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)

            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 10)).foregroundStyle(Theme.Ink.label)
                Text("Private by design. Screenshots go to your configured LLM endpoint, never a Sentient server.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 560)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { gate.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    // MARK: Sentient's grants — native prompts first, the guide as the fallback

    private var micSpeechNote: String {
        switch gate.micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "recommended"
        case .denied:   return "off"
        }
    }

    private func fixMicSpeech() {
        switch gate.micSpeech {
        case .granted:
            break
        case .notAsked:
            Task { _ = await VoiceCapture.requestPermissions(); gate.refresh() }
        case .denied:
            // Deep-link to whichever grant is actually the blocker (mic first — it gates speech).
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.openSpeechRecognitionSettings()
            }
        }
    }

    /// Sentient's own Accessibility — drag-authorizable; the guide carries Sentient itself as the
    /// drag card so the user can drop it into the list.
    private func fixSentientAccessibility() {
        guard !gate.sentientAccessibility else { return }
        PermissionGuide.shared.guide(.accessibility, dragging: Bundle.main.bundleURL)
    }

    /// Sentient's own Screen Recording — same drag flow.
    private func fixSentientScreen() {
        guard !gate.sentientScreen else { return }
        PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
    }
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
