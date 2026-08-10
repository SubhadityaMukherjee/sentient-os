//
//  OnboardingEndpointView.swift
//  Sentient OS macOS
//
//  Replaces the old codex-login onboarding step. The user enters their local LLM endpoint
//  (OpenAI-compatible: baseURL, optional API key, model name), tests connectivity, and continues.
//  Defaults pre-fill for Ollama (http://localhost:11434/v1 + llama3.2); the user adjusts for
//  LM Studio (http://localhost:1234/v1), llama.cpp server, vLLM, MLX server, etc.
//
//  Mirrors the layout of OnboardingCodexLoginView so the cascade feels native.
//

import SwiftUI

// MARK: - Shared onboarding bits (moved here from the deleted OnboardingCodexSteps.swift)

/// The monospace-caps whisper label every onboarding screen opens with.
struct OnboardingWhisper: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .kerning(2)
            .foregroundStyle(Theme.faint)
    }
}

/// A green-dot "this step is done" line (shared across onboarding screens).
struct OnboardingDoneLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 11) {
            HealthDot(color: Theme.Ink.green)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.statusInk)
        }
    }
}

// MARK: - Onboarding endpoint view

struct OnboardingEndpointView: View {
    let onContinue: () -> Void

    @State private var baseURL: String = LocalLLMConfig.defaultBaseURL
    @State private var apiKey: String = ""
    @State private var model: String = LocalLLMConfig.defaultModel
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var testOK: Bool = false

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("CONNECT LOCAL LLM")

            Text("Point Sentient at any OpenAI-compatible local endpoint.\nOllama, LM Studio, llama.cpp server, vLLM, MLX server — your pick.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            VStack(spacing: 14) {
                endpointRow(label: "Base URL", placeholder: "http://localhost:11434/v1", text: $baseURL)
                endpointRow(label: "Model", placeholder: "llama3.2", text: $model)
                endpointRow(label: "API key (optional)", placeholder: "leave blank for local servers", text: $apiKey)

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(testOK ? Theme.Ink.green : .red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await runTest() }
                } label: {
                    HStack(spacing: 8) {
                        if testing { ProgressView().controlSize(.mini) }
                        Text(testing ? "testing…" : "Test connection")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(testing || !canSave)
            }
            .frame(maxWidth: 560)

            OnboardingNextButton(title: "Continue", enabled: canSave, action: save)

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .onAppear {
            // Pre-fill from current config (so a re-visit shows what's saved).
            let c = LocalLLMConfig.current()
            baseURL = c.baseURL
            apiKey = c.apiKey
            model = c.model
        }
    }

    @ViewBuilder
    private func endpointRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.Ink.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func runTest() async {
        testing = true
        testResult = nil
        // Save first so LocalLLM sees the new config, then ping.
        LocalLLMConfig.save(baseURL: baseURL, apiKey: apiKey, model: model)
        await LocalLLM.shared.reloadConfig()
        let err = await LocalLLM.shared.ping()
        testing = false
        if let err {
            testOK = false
            testResult = "✗ \(err.prefix(140))"
        } else {
            testOK = true
            testResult = "✓ connected — \(model) answered"
        }
    }

    private func save() {
        LocalLLMConfig.save(baseURL: baseURL, apiKey: apiKey, model: model)
        Task { await LocalLLM.shared.reloadConfig() }
        onContinue()
    }
}

#Preview("Onboarding — endpoint") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingEndpointView(onContinue: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
