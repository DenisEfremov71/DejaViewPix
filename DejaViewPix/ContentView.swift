//
//  ContentView.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import AlbumAI
import SwiftUI

struct ContentView: View {
    @State private var prompt = ""
    @State private var reply = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let client = ClaudeClient(apiKey: { try APIConfig.claudeAPIKey() })

    private var canSend: Bool {
        !isLoading
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Ask Claude something…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            Button {
                Task { await sendPrompt() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            ScrollView {
                Text(reply)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private func sendPrompt() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            reply = try await client.send(prompt)
        } catch is CancellationError {
            // Task was cancelled; nothing to show.
        } catch let error as URLError where error.code == .cancelled {
            // Same, coming from URLSession.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
