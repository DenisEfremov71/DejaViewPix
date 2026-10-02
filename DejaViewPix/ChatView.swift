//
//  ChatView.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import AlbumAI
import SwiftUI

/// The reply as it streams in, plus its metrics.
struct StreamedReply {
    var text = ""
    var inputTokens: Int?
    var outputTokens: Int?
    var stopReason: String?
    var timeToFirstToken: Duration?
    var totalTime: Duration?
}

/// The Day 1–2 streaming chat screen, kept for checking the client by hand.
struct ChatView: View {
    @State private var prompt = ""
    @State private var reply: StreamedReply?
    @State private var retryMessage: String?
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var simulateOverload = false
    @FocusState private var isPromptFocused: Bool

    #if DEBUG
    private let client = ClaudeClient(
        session: SimulatedOverload.session,
        apiKey: { try APIKeyStore.claude.load() }
    )
    #else
    private let client = ClaudeClient(apiKey: { try APIKeyStore.claude.load() })
    #endif

    private var isLoading: Bool {
        sendTask != nil
    }

    private var canSend: Bool {
        !isLoading
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Ask Claude something…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isPromptFocused)
                .submitLabel(.send)
                .submitOnReturn($prompt) {
                    if canSend { send() } else { isPromptFocused = false }
                }

            #if DEBUG
            Toggle("Simulate overload (two 529s)", isOn: $simulateOverload)
                .font(.footnote)
            #endif

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

            if let retryMessage {
                Text(retryMessage)
                    .foregroundStyle(.orange)
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
        .dismissesKeyboardOnTap($isPromptFocused)
    }

    // MARK: - Sending

    private func send() {
        isPromptFocused = false
        let prompt = prompt
        reply = nil
        errorMessage = nil
        infoMessage = nil

        retryMessage = nil
        #if DEBUG
        SimulatedOverload.arm(count: simulateOverload ? 2 : 0)
        #endif

        sendTask = Task {
            defer {
                sendTask = nil
                retryMessage = nil
            }

            let clock = ContinuousClock()
            let start = clock.now
            do {
                for try await event in client.stream(prompt) {
                    switch event {
                    case .retrying(let attempt, let maxAttempts, let delay, _):
                        retryMessage = "Server busy, retrying in \(Self.formatSeconds(delay)) "
                            + "(attempt \(attempt) of \(maxAttempts))…"
                    case .messageStart(_, let usage):
                        retryMessage = nil
                        reply = StreamedReply(inputTokens: usage.inputTokens)
                    case .textDelta(_, let text):
                        if reply?.timeToFirstToken == nil {
                            reply?.timeToFirstToken = start.duration(to: clock.now)
                        }
                        reply?.text += text
                    case .messageDelta(let stopReason, let outputTokens):
                        reply?.stopReason = stopReason
                        reply?.outputTokens = outputTokens
                    default:
                        break
                    }
                }
                // A cancelled stream ends quietly, so check before reporting success.
                try Task.checkCancellation()
                reply?.totalTime = start.duration(to: clock.now)
            } catch is CancellationError {
                infoMessage = "Request cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reply

    private func replyPanel(_ reply: StreamedReply) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 4) {
                LabeledContent(
                    "Tokens in / out",
                    value: "\(reply.inputTokens.map(String.init) ?? "—") / \(reply.outputTokens.map(String.init) ?? "—")"
                )
                LabeledContent("First token", value: reply.timeToFirstToken.map(Self.format) ?? "—")
                LabeledContent("Total", value: reply.totalTime.map(Self.format) ?? "—")
                LabeledContent("Stop reason", value: reply.stopReason ?? "—")
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

    nonisolated private static func format(_ latency: Duration) -> String {
        let milliseconds = latency / .milliseconds(1)
        return "\(Int(milliseconds.rounded())) ms"
    }

    nonisolated private static func formatSeconds(_ duration: Duration) -> String {
        let seconds = duration / .seconds(1)
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
}

#Preview {
    ChatView()
}
