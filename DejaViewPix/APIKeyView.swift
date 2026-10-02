//
//  APIKeyView.swift
//  DejaViewPix
//

import AlbumAI
import SwiftUI

/// Saves the Claude API key in the Keychain. The key is never shown again after saving.
struct APIKeyView: View {
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var keyStatus: String?

    private var trimmedKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
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

            Spacer(minLength: 0)
        }
        .padding()
        .onAppear(perform: refreshKeyStatus)
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
}

#Preview {
    APIKeyView()
}
