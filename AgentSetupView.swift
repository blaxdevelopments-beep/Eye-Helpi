//
//  AgentSetupView.swift
//  Eye~Helpi
//
//  Companion screen for the local Python agent (eye_helpi_agent/): shows how
//  to run it, which device-control tools it exposes, and lets the user point
//  this app at the machine running Ollama. Also the security desk: Keychain
//  key management with pasteboard wipe-on-save, a cloud connection test, and
//  a live cloud usage meter.
//

import SwiftUI
import UIKit

struct AgentSetupView: View {

    @State private var host = AgentConfig.host
    @State private var cloudNote = ""
    @State private var checkingCloud = false
    @State private var keyDrafts: [String: String] = [:]
    @State private var keyNotes: [String: String] = [:]
    @ObservedObject private var usage = CloudUsage.shared
    @AppStorage("eyehelpi.replySize") private var replySizeRaw = ReplyTextSize.standard.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent host") {
                    TextField("http://192.168.1.20:11434", text: $host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save host") {
                        AgentConfig.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                Section("Reply reading size") {
                    Picker("Transcript text", selection: $replySizeRaw) {
                        ForEach(ReplyTextSize.allCases) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Scales the chat bubbles and search results in every conversation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cloud fallback key") {
                    if ApiKeyManager.shared.has(key: OpenAIFallbackService.keyName) {
                        Label("OpenAI key is set - Eye~Helpi falls back to the cloud when Ollama is unreachable.", systemImage: "cloud.fill")
                            .font(.footnote)
                            .foregroundStyle(EyeTheme.accent)
                    } else {
                        Label("No OpenAI key set - the cloud fallback is off and Eye~Helpi only answers while Ollama is reachable.", systemImage: "cloud")
                            .font(.footnote)
                    }

                    Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                        Label("Get an OpenAI API key", systemImage: "key.fill")
                            .font(.callout)
                    }
                    Text("After creating the key, enter its value under Stored API keys below - it is stored in the keychain, never in code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        checkCloud()
                    } label: {
                        if checkingCloud {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Testing cloud connection...")
                            }
                        } else {
                            Label("Test cloud connection", systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checkingCloud)

                    if !cloudNote.isEmpty {
                        Text(cloudNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Stored API keys") {
                    ForEach(AgentConfig.managedKeys, id: \.name) { key in
                        keyRow(key)
                    }
                    Text("Values live in the Keychain on this device only - never in code, never iCloud-synced. Saving a key wipes the pasteboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cloud fallback usage") {
                    Label("\(usage.requests) cloud turns, ~\(usage.estimatedTokens) tokens (chars / 4 estimate)", systemImage: "chart.bar.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        usage.reset()
                    } label: {
                        Label("Reset usage counters", systemImage: "arrow.counterclockwise")
                            .font(.footnote)
                    }
                }

                Section("Security hardening") {
                    Label("Keys are readable only on this device while it is unlocked (Keychain kSecAttrAccessibleWhenUnlockedThisDeviceOnly).", systemImage: "lock.iphone")
                        .font(.footnote)
                    Label("Cloud traffic runs over TLS 1.2+ with optional SPKI certificate pinning (see TLS_PINS.plist.example).", systemImage: "lock.shield")
                        .font(.footnote)
                    Label("Saving a key clears the pasteboard so secrets never linger.", systemImage: "scissors")
                        .font(.footnote)
                }

                Section("Run the agent on your computer") {
                    step("Runs on macOS, Linux or Windows - the agent detects the OS and adapts every tool")
                    step("Install Ollama from ollama.com and start the app")
                    step("ollama pull llama3.2-vision")
                    step("pip install -r eye_helpi_agent/requirements.txt")
                    step("python eye_helpi_agent/main.py")
                    step("Connect this phone to the same Wi-Fi and set the host above to the computer's LAN address")
                }

                Section("Visual assistant web app") {
                    step("cd eyehelpi-web && npm run install:all")
                    step("Install Ollama and run ollama pull llama3.2-vision")
                    step("npm run dev:server and npm run dev:client")
                    step("Live camera vision (local COCO-SSD + Ollama llama3.2-vision), voice commands (browser speech)")
                    Link(destination: AgentConfig.webAppURL) {
                        Label("Open Eye~Helpi Web Assistant", systemImage: "safari.fill")
                            .font(.callout)
                    }
                }

                Section("Device control tools") {
                    ForEach(AgentConfig.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.name)
                                .font(.callout.monospaced())
                            Text(tool.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Safety") {
                    Label("Recordings older than one hour are only deleted after Eye~Helpi asks you to approve the disposal.", systemImage: "hand.raised.fill")
                        .font(.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(EyeTheme.background.ignoresSafeArea())
            .navigationTitle("Agent Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func keyRow(_ key: (name: String, title: String, help: URL?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                if ApiKeyManager.shared.has(key: key.name) {
                    StatusChip(text: "stored", color: .green)
                } else {
                    StatusChip(text: "not set", color: .secondary)
                }
            }
            SecureField(
                "Paste or type the value for \(key.name)",
                text: Binding(
                    get: { keyDrafts[key.name] ?? "" },
                    set: { keyDrafts[key.name] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if let help = key.help {
                Link("Where do I get this key?", destination: help)
                    .font(.footnote)
            }

            Button("Save \(key.name)") {
                saveKey(key.name)
            }
            .font(.footnote.weight(.semibold))

            if let note = keyNotes[key.name] {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func saveKey(_ name: String) {
        let value = (keyDrafts[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            keyNotes[name] = "Nothing to save - the field is empty."
            return
        }
        ApiKeyManager.shared.set(key: name, value: value)
        keyDrafts[name] = ""
        keyNotes[name] = "Stored in the keychain (this device only). Pasteboard wiped for safety."
        // FinTech hygiene: a pasted secret never lingers on the pasteboard.
        UIPasteboard.general.setItems(
            [],
            options: [.localOnly: true, .expirationDate: Date()]
        )
    }

    private func checkCloud() {
        checkingCloud = true
        cloudNote = ""
        Task {
            defer { checkingCloud = false }
            guard let fallback = OpenAIFallbackService() else {
                cloudNote = "No key stored yet - create one above and enter its value under Stored API keys."
                return
            }
            do {
                let (valid, detail) = try await fallback.isKeyValid()
                cloudNote = valid
                    ? "Cloud connected. \(OpenAIFallbackService.modelName) is ready as the fallback brain."
                    : "The cloud refused us (\(detail ?? "key rejected")). Check billing or create a fresh key, then enter its value in the app."
            } catch {
                cloudNote = "Could not reach the OpenAI cloud (\(error.localizedDescription))."
            }
        }
    }

    private func step(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote.monospaced())
        } icon: {
            Image(systemName: "1.circle.fill")
                .foregroundStyle(EyeTheme.accent)
        }
    }
}

#Preview {
    AgentSetupView()
}