//
//  OvernightCaution.swift
//  Sentient OS macOS
//
//  Cycle-failure classification + the morning-after caution. `classify(_:)` turns a cycle failure
//  into one of the three reasons a user can actually act on or should simply know about — codex
//  signed out · no internet · usage limit — and serves BOTH failure surfaces: the UNATTENDED 3am
//  run persists it via `record(_:)` (at ProactiveCycle's catch sites, the one choke point every
//  codex call already funnels typed errors through) and the home renders it as a quiet amber
//  capsule (HomeView.cautionBanner); the WATCHED processing takeover shows the same kind live on
//  its failed screen (ProcessingView.failedView — "Codex isn't logged in" + a login button). Any
//  later fully successful cycle clears the caution; so does the banner's ✕. Other failure kinds
//  stay log/Sentry territory — no banner.
//
//  Key methods: classify(_:) · record(_:) (3am only) · latest() · clear()
//

import Foundation
import Network
import os

enum OvernightCaution {

    enum Kind: String, Codable {
        case endpointMissing   // no local LLM endpoint configured when the night's work started
        case noInternet        // the Mac was offline, so the endpoint couldn't be reached
        case failed            // the endpoint returned an error or timed out

        /// The banner line — quiet, first-person, honest about what happens next.
        var message: String {
            switch self {
            case .endpointMissing: return "I couldn't work last night — no local LLM endpoint is set. Configure one in Settings and I'll catch up tonight."
            case .noInternet:      return "No internet last night, so I couldn't reach your local LLM. I'll try again tonight."
            case .failed:          return "Last night's run hit an error from your local LLM. Your analysis is saved; I'll try again tonight."
            }
        }
    }

    struct Record: Codable {
        let kind: Kind
        let date: Date
    }

    private static let key = "overnight.caution"

    /// The caution the home should show, if any.
    static func latest() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// A later cycle succeeded, or the user dismissed the banner.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Classify a cycle failure into a user-facing kind (nil = unclassifiable — the UI only ever
    /// states what was verified). Shared by the 3am run (record + banner) and the watched
    /// takeover's failed screen.
    static func classify(_ error: Error) async -> Kind? {
        // Typed errors first — certain.
        switch error {
        case LocalLLM.LLMError.notConfigured:
            return .endpointMissing
        case LocalLLM.LLMError.network:
            return await networkUp() ? .failed : .noInternet
        case LocalLLM.LLMError.http, LocalLLM.LLMError.badEndpoint, LocalLLM.LLMError.agentLoopDisabled:
            return .failed
        // ponytail: legacy error cases (vault/proactive/gift) currently surface as .failed when
        // they bubble up; the agent-loop restoration in phase 2 brings typed cases back here.
        default:
            return await networkUp() ? .failed : .noInternet
        }
    }

    /// Persist a classified kind as the morning-after caution (3am runs only; nil records nothing).
    static func record(_ kind: Kind?) {
        guard let kind else { return }
        if let data = try? JSONEncoder().encode(Record(kind: kind, date: Date())) {
            UserDefaults.standard.set(data, forKey: key)
        }
        Log("OvernightCaution: recorded .\(kind.rawValue)")
        // Environment weather (signed out / offline / usage limit), not an app defect — product
        // telemetry, so TelemetryDeck, never the Sentry issue feed (2026-07-12).
        Analytics.signal("Scheduler.caution", parameters: ["kind": kind.rawValue])
    }

    /// One NWPathMonitor snapshot — the first path update arrives immediately; guarded so the
    /// continuation can never resume twice.
    private static func networkUp() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                guard resumed.withLock({ done in
                    if done { return false }
                    done = true
                    return true
                }) else { return }
                monitor.cancel()
                cont.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
