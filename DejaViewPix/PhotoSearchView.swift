//
//  PhotoSearchView.swift
//  DejaViewPix
//

import AlbumAI
import OSLog
import Photos
import SwiftUI

/// Natural-language search: runs the tool loop and shows each round as it finishes,
/// then the photos it found.
struct PhotoSearchView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var query = ""
    @State private var rounds: [ToolLoopRound] = []
    @State private var result: ToolLoopResult?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isQueryFocused: Bool

    private static let log = Logger(subsystem: "DejaViewPix", category: "search")

    private let loop = ToolLoop(
        client: ClaudeClient(apiKey: { try APIKeyStore.claude.load() }),
        tools: PhotoTools(library: PhotoLibrary(), geocoder: PlaceGeocoder(), timeZone: .current)
    )

    private var isSearching: Bool {
        searchTask != nil
    }

    private var canSearch: Bool {
        !isSearching
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && access != .denied && access != .restricted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accessBanner

                TextField("e.g. photos from Whistler last winter", text: $query, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($isQueryFocused)
                    .submitLabel(.search)
                    .submitOnReturn($query, action: search)

                HStack(spacing: 12) {
                    Button("Search", action: search)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSearch)

                    if isSearching {
                        Button("Cancel", role: .cancel) {
                            searchTask?.cancel()
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

                ForEach(rounds, id: \.number, content: roundView)

                if let result {
                    resultView(result)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissesKeyboardOnTap($isQueryFocused)
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed access in Settings.
            if phase == .active {
                access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            }
        }
    }

    // MARK: - Photo access

    @ViewBuilder
    private var accessBanner: some View {
        switch access {
        case .authorized:
            EmptyView()
        case .notDetermined:
            banner("Deja View Pix needs access to your photos to search them.") {
                Button("Allow Access") {
                    Task { await requestAccess() }
                }
            }
        case .limited:
            banner("Limited access: only the photos you selected are searched.") {
                Button("Change in Settings", action: openSettings)
            }
        case .denied:
            banner("Photo access is off, so there is nothing to search. Turn it on in Settings.") {
                Button("Open Settings", action: openSettings)
            }
        case .restricted:
            banner("Photo access is restricted on this device, for example by Screen Time, and can't be changed here.") {
                EmptyView()
            }
        @unknown default:
            banner("Unknown photo access state.") { EmptyView() }
        }
    }

    private func banner(_ message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
            action()
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 8))
    }

    private func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    // MARK: - Searching

    private func search() {
        isQueryFocused = false
        guard canSearch else { return }
        let query = query
        rounds = []
        result = nil
        errorMessage = nil

        searchTask = Task {
            defer { searchTask = nil }

            if access == .notDetermined {
                await requestAccess()
            }
            guard access == .authorized || access == .limited else {
                errorMessage = "Photo access is needed to search."
                return
            }

            let system = SearchPrompt.system(now: .now, timeZone: .current)
            do {
                result = try await loop.run(query, system: system) { @MainActor round in
                    rounds.append(round)
                    for call in round.toolCalls {
                        Self.log.debug("""
                            round \(round.number) \(call.name)(\(call.input.jsonString)) \
                            → \(call.output.isError ? "ERROR " : "")\(call.output.content)
                            """)
                    }
                }
            } catch is CancellationError {
                errorMessage = "Search cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Trace and results

    private func roundView(_ round: ToolLoopRound) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Round \(round.number) · \(Self.format(round.latency)) · \(round.usage.inputTokens) in / \(round.usage.outputTokens) out · \(round.stopReason ?? "—")")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(round.toolCalls, id: \.id) { call in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.name)(\(call.input.jsonString))")
                        .font(.caption.monospaced())
                    Text("→ " + Self.truncated(call.output.content))
                        .font(.caption2.monospaced())
                        .foregroundStyle(call.output.isError ? .red : .secondary)
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    private func resultView(_ result: ToolLoopResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.finalText)
                .textSelection(.enabled)

            Text("\(result.photoIDs.count) photos · \(result.rounds.count) rounds · \(result.usage.inputTokens) in / \(result.usage.outputTokens) out tokens")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                ForEach(result.photoIDs, id: \.self) { id in
                    AssetThumbnail(id: id)
                }
            }
        }
    }

    nonisolated private static func format(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    nonisolated private static func truncated(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : text.prefix(limit) + "…"
    }
}

/// A square thumbnail for a PHAsset local identifier.
struct AssetThumbnail: View {
    let id: String
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: id) {
                image = await Self.load(id, side: 80 * displayScale)
            }
    }

    private static func load(_ id: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // One callback with the final image, so the continuation resumes exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

#Preview {
    PhotoSearchView()
}
