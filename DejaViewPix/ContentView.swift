//
//  ContentView.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import AlbumAI
import SwiftUI

struct ContentView: View {
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var keyStatus: String?

    @State private var prompt = ""
    @State private var reply: ClaudeReply?
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var sendTask: Task<Void, Never>?

    private let client = ClaudeClient(apiKey: { try APIKeyStore.claude.load() })

    private var isLoading: Bool {
        sendTask != nil
    }

    private var canSend: Bool {
        !isLoading
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            apiKeySection

            Divider()

            TextField("Ask Claude something…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            HStack(spacing: 12) {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)

                if isLoading {
                    Button("Cancel", role: .cancel) {
                        sendTask?.cancel()
                    }
                    .buttonStyle(.bordered)

                    ProgressView()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let infoMessage {
                Text(infoMessage)
                    .foregroundStyle(.secondary)
            }

            if let reply {
                replyPanel(reply)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .onAppear(perform: refreshKeyStatus)
    }

    // MARK: - API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField(
                    hasSavedKey ? "Enter a new key to replace it" : "Claude API key",
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button("Save", action: saveKey)
                    .buttonStyle(.bordered)
                    .disabled(trimmedKeyInput.isEmpty)
            }

            if let keyStatus {
                Text(keyStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey() {
        do {
            try APIKeyStore.claude.save(trimmedKeyInput)
            apiKeyInput = ""
            hasSavedKey = true
            keyStatus = "Key saved in the Keychain."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func refreshKeyStatus() {
        do {
            hasSavedKey = try APIKeyStore.claude.read() != nil
            keyStatus = hasSavedKey ? "A key is saved in the Keychain." : "No key saved yet."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    // MARK: - Sending

    private func send() {
        let prompt = prompt
        reply = nil
        errorMessage = nil
        infoMessage = nil

        sendTask = Task {
            defer { sendTask = nil }

            do {
                reply = try await client.send(prompt)
            } catch is CancellationError {
                infoMessage = "Request cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reply

    private func replyPanel(_ reply: ClaudeReply) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 4) {
                LabeledContent("Tokens in / out", value: "\(reply.usage.inputTokens) / \(reply.usage.outputTokens)")
                LabeledContent("Latency", value: Self.format(reply.latency))
                LabeledContent("Stop reason", value: reply.stopReason ?? "—")
                LabeledContent("Request ID") {
                    Text(reply.requestID ?? "—")
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.footnote)
            .padding(10)
            .background(.quaternary, in: .rect(cornerRadius: 8))

            if reply.stopReason == "max_tokens" {
                Text("Reply truncated: reached the max_tokens limit.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                Text(reply.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private static func format(_ latency: Duration) -> String {
        let milliseconds = latency / .milliseconds(1)
        return "\(Int(milliseconds.rounded())) ms"
    }
}

#Preview {
    ContentView()
}
