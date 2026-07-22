//
//  ComputerUseGate.swift
//  Sentient OS macOS
//
//  The first-use permission gate for everything that acts on the Mac. Every computer-use surface
//  (the home command bar, Sidekick's hotkey, a proactive card's fire) funnels through
//  `intercept(_:)`: while any REQUIRED action grant is missing — the Codex Computer Use helper's
//  Accessibility and Screen Recording — it stashes the pending action, raises the one-time setup
//  window (ComputerUseGateView), and fires the action when the user taps Continue. Sentient's own
//  grants ride along as OPTIONAL rows (Microphone & Speech — Sidekick's voice; Screen Recording —
//  the screen-context snapshot): missing either never gates anything — no mic means hold-to-talk
//  stays off (tap-to-type and typed commands still work), no screen grant means commands run
//  text-only. Each optional grant is offered exactly once (persisted flags), and a voice HOLD
//  against a DENIED mic re-raises the window as a non-blocking fix surface (presentVoiceFixIfDenied
//  — a denied grant has no native prompt left to show). Closing the window instead cancels the
//  pending action. All required grants green and both optionals offered means it never appears at
//  all. Status probes reuse Permissions/VoiceCapture (the helper's grants are system-TCC, read via
//  our FDA).
//
//  Key methods: intercept(_:) · refresh() · continueNow()
//

import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
@Observable
final class ComputerUseGate {

    static let shared = ComputerUseGate()
    private init() {}

    // MARK: Grant status (probed, not cached beyond the last refresh)

    /// Sentient's mic + speech recognition — Sidekick's ears. OPTIONAL: without it, hold-to-talk
    /// stays off (the first hold flashes the mic notice); tap-to-type and typed commands are
    /// untouched. Detail preserved for the fix action.
    enum MicSpeechState { case granted, notAsked, denied }
    private(set) var micSpeech: MicSpeechState = .notAsked

    /// Sentient's own Screen Recording — the screen context snapshot. OPTIONAL: without it,
    /// Sidekick runs text-only; it never gates an action.
    private(set) var sentientScreen = false

    /// The Codex Computer Use helper's presence + its two system-TCC grants (its hands and eyes).
    private(set) var helperOnDisk = false
    private(set) var helperAccessibility = false
    private(set) var helperScreen = false

    /// The REQUIRED grants — what the gate holds actions for. Sentient's own two (Microphone &
    /// Speech, Screen Recording) are deliberately absent: optional rows, shown but never blocking.
    var allRequiredGranted: Bool {
        helperAccessibility && helperScreen
    }

    // MARK: The gate

    /// Persisted so each of Sentient's OPTIONAL grants (Screen Recording · Microphone & Speech)
    /// is offered exactly once in the app's lifetime. The gate blocks only on REQUIRED grants, so
    /// without these a user who already had the Codex helper's grants (e.g. set up via the
    /// ChatGPT app) would sail straight past and never be pitched Sentient's own two. Cleared by
    /// FactoryReset so a rebuild re-offers them.
    static let screenRecordingOfferedKey = "computerUse.screenRecordingOffered"
    static let micSpeechOfferedKey = "computerUse.micSpeechOffered"
    private static var screenRecordingOffered: Bool {
        get { UserDefaults.standard.bool(forKey: screenRecordingOfferedKey) }
        set { UserDefaults.standard.set(newValue, forKey: screenRecordingOfferedKey) }
    }
    private static var micSpeechOffered: Bool {
        get { UserDefaults.standard.bool(forKey: micSpeechOfferedKey) }
        set { UserDefaults.standard.set(newValue, forKey: micSpeechOfferedKey) }
    }

    private var pending: (@MainActor () -> Void)?
    private var presentedBlocking = false   // window up because a REQUIRED grant is missing (vs. the optional offer)
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// The one entry point. Returns true when the gate took over (window up, action stashed) and
    /// the caller must abort; false when the caller may just proceed.
    /// ponytail: phase-2 — computer-use actions are gated off in phase 1, so this always passes
    /// through. Restored when the AX-API local-LLM agent loop lands.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        action()
        return false
    }

    /// Gate a surface that must not even OPEN while a required grant is missing — the Sidekick
    /// hotkey PRESS, which has no command to hold yet. Without this the notch drops open to listen
    /// and only meets the gate at submit(), after a whole listen-and-transcribe dance. Same
    /// show/re-show behavior as `intercept`; there's simply nothing to fire on Continue, so the
    /// user re-presses to talk once everything's granted. Returns true when the gate took over and
    /// the caller must abort (don't open the notch).
    @discardableResult
    func interceptBeforeStart() -> Bool {
        intercept({})
    }

    /// ponytail: phase-2 — voice-fix surface restored when the AX-API agent loop lands; for now
    /// the gate is dormant, so denied-mic holds just no-op.
    func presentVoiceFixIfDenied() -> Bool {
        return false
    }

    /// Re-probe all four grants (cheap; the TCC reads are two tiny indexed SELECTs).
    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .authorized && speech == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
        // Preflight is the running process's view — it stays false until a relaunch even after the
        // user flips the switch. The TCC read (we hold FDA) is the LIVE truth, so the row can go
        // green the moment they grant; the tip still says a restart is needed for capture.
        sentientScreen = Permissions.hasScreenRecording()
            || Permissions.isTCCGranted(service: "kTCCServiceScreenCapture",
                                        clientBundleID: Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS")
        helperOnDisk = Permissions.computerUseHelperURL() != nil
        helperAccessibility = Permissions.isTCCGranted(
            service: "kTCCServiceAccessibility",
            clientBundleID: Permissions.computerUseHelperBundleID)
        helperScreen = Permissions.isTCCGranted(
            service: "kTCCServiceScreenCapture",
            clientBundleID: Permissions.computerUseHelperBundleID)
    }

    /// The window's main button — dismiss and fire the held action. Only ever fires once every
    /// required grant is green (the button is disabled until then); the re-probe + guard here make
    /// that a hard invariant, so a stale tap can never launch a feature that would just fail.
    func continueNow() {
        refresh()
        guard allRequiredGranted else {
            Log("ComputerUseGate: Continue blocked — a required grant is still missing")
            return
        }
        HealthCaution.latchComputerUse()   // the gate's moment of truth — regressions may now banner
        let action = pending
        pending = nil
        Analytics.signal("PermissionGate.continued", parameters: ["all_granted": "true"])
        dismissWindow()
        action?()
    }

    // MARK: Window lifecycle (AppKit-owned — it must be able to appear over OTHER apps, since
    // Sidekick fires from anywhere; a SwiftUI Window scene can't be raised from the coordinator)

    private func present() {
        if window == nil {
            let hosting = NSHostingController(rootView: ComputerUseGateView(gate: self))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.isMovableByWindowBackground = true
            window = w
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.windowClosed() }
            }
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    private func dismissWindow() {
        PermissionGuide.shared.close()   // take any drag panel down with the gate
        window?.close()                  // willClose → windowClosed(), which finds pending already nil on Continue
    }

    /// The red button / X. A BLOCKING gate drops the held action (never fired blind — a required
    /// grant is missing). The optional-grants offer is non-blocking, so dismissing it still fires
    /// the command the user actually asked for.
    private func windowClosed() {
        if let action = pending {
            pending = nil
            if presentedBlocking {
                Log("ComputerUseGate: setup window closed — held action dropped (required grant missing)")
            } else {
                Log("ComputerUseGate: optional-grants offer dismissed — firing the held command")
                action()
            }
        }
        PermissionGuide.shared.close()
    }
}
