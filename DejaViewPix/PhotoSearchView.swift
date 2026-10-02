//
//  PhotoSearchView.swift
//  DejaViewPix
//

import AlbumAI
import Photos
import SwiftUI

/// Natural-language search. Every phase has its own screen, and so does each photo access
/// state.
struct PhotoSearchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .notDetermined:
                    PhotoAccessIntroView {
                        Task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                    }
                case .denied, .restricted:
                    PhotoAccessBlockedView(status: access)
                default:
                    SearchScreen(isLimited: access == .limited)
                }
            }
            .navigationTitle("Deja View Pix")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed access in Settings.
            if phase == .active {
                access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            }
        }
    }
}

private struct SearchScreen: View {
    let isLimited: Bool

    @State private var model = SearchModel()
    @State private var query = ""
    @State private var submission: Submission?
    @FocusState private var isQueryFocused: Bool

    private struct Submission: Equatable {
        let id = UUID()
        let text: String
    }

    private static let suggestions = [
        "photos from Whistler last winter",
        "my favorite videos",
        "photos from last month",
        "screenshots from this year",
    ]

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var phaseKind: Int {
        switch model.phase {
        case .idle: 0
        case .searching: 1
        case .results: 2
        case .empty: 3
        case .failed: 4
        }
    }

    private var isSearching: Bool {
        if case .searching = model.phase { true } else { false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLimited {
                    LimitedAccessBanner()
                }
                searchField
                phaseView
                    // Animate moving between screens, not edits within one: a removed chip
                    // should update the grid at once.
                    .animation(.default, value: phaseKind)
                if !isSearching, !model.rounds.isEmpty {
                    SearchDetailsView(rounds: model.rounds, metrics: model.metrics)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissesKeyboardOnTap($isQueryFocused)
        // A new submission cancels the previous search; clearing it is Cancel.
        .task(id: submission) {
            guard let submission else { return }
            await model.search(submission.text, submission: submission.id)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Describe the photos you want", text: $query, axis: .vertical)
                .lineLimit(1...4)
                .focused($isQueryFocused)
                .submitLabel(.search)
                .submitOnReturn($query, action: submit)
            if !query.isEmpty {
                Button {
                    query = ""
                    isQueryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    private func submit() {
        isQueryFocused = false
        guard !trimmedQuery.isEmpty else { return }
        submission = Submission(text: trimmedQuery)
    }

    // MARK: - Phases

    @ViewBuilder
    private var phaseView: some View {
        switch model.phase {
        case .idle:
            suggestionsView

        case .searching(let status):
            HStack(spacing: 12) {
                ProgressView()
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { submission = nil }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)

        case .results(let outcome):
            VStack(alignment: .leading, spacing: 12) {
                header(outcome)
                PhotoGrid(photos: outcome.photos, filters: outcome.filters)
                    .opacity(model.isUpdating ? 0.6 : 1)
            }

        case .empty(let outcome):
            VStack(alignment: .leading, spacing: 12) {
                header(outcome)
                ContentUnavailableView(
                    "No Matching Photos",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(outcome.filters.isEmpty
                        ? "Try describing the photos another way."
                        : "Remove a filter to widen the search.")
                )
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Search Didn't Finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let submission {
                    Button("Try Again") { self.submission = Submission(text: submission.text) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    query = suggestion
                    submit()
                } label: {
                    Label(suggestion, systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 8)
    }

    /// The summary (or a note that the user's edits replaced it), the chips and the count.
    private func header(_ outcome: SearchModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = outcome.summary {
                Text(summary)
                    .textSelection(.enabled)
            } else {
                Label("Filters edited. Searched on your iPhone, without Claude.", systemImage: "slider.horizontal.3")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            let chips = outcome.filters.chips
            if !chips.isEmpty {
                FilterChipsView(chips: chips) { old, new in
                    model.edit(old, to: new)
                }
            }

            if !outcome.photos.isEmpty {
                Text(countLabel(outcome))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func countLabel(_ outcome: SearchModel.Outcome) -> String {
        let count = outcome.photos.count
        let noun = count == 1 ? "photo" : "photos"
        return outcome.hasMore ? "Showing the first \(count) \(noun). More match." : "\(count) \(noun)"
    }
}

/// The round-by-round trace and cost of the last query, for debugging and the Day 8
/// model comparison.
private struct SearchDetailsView: View {
    let rounds: [ToolLoopRound]
    let metrics: QueryMetrics?

    var body: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 8) {
                if let metrics {
                    Text(Self.metricsLabel(metrics))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(rounds, id: \.number, content: roundView)
            }
            .padding(.top, 8)
        }
        .font(.footnote)
    }

    private func roundView(_ round: ToolLoopRound) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Round \(round.number) · \(Self.format(round.latency)) · \(round.usage.inputTokens) in / \(round.usage.outputTokens) out · \(round.stopReason ?? "—")")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if round.toolCalls.isEmpty {
                // Claude answered in prose; the loop asked it to call present_results.
                if !round.text.isEmpty {
                    Text(Self.truncated(round.text))
                        .font(.caption)
                        .italic()
                }
                Text("→ no tool call; asked for present_results")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }

            ForEach(round.toolCalls, id: \.id) { call in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.name)(\(call.input.jsonString))")
                        .font(.caption.monospaced())
                    Text("→ " + Self.truncated(call.output.content))
                        .font(.caption2.monospaced())
                        .foregroundStyle(call.output.isError ? .red : .secondary)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    nonisolated private static func metricsLabel(_ metrics: QueryMetrics) -> String {
        let cost = metrics.cost.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(4))) } ?? "cost unknown"
        return "\(metrics.rounds) rounds · \(format(metrics.latency)) · "
            + "\(metrics.usage.inputTokens) in / \(metrics.usage.outputTokens) out tokens · \(cost)"
    }

    nonisolated private static func format(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded())) ms"
    }

    nonisolated private static func truncated(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : text.prefix(limit) + "…"
    }
}

#Preview {
    PhotoSearchView()
}
