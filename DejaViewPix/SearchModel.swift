//
//  SearchModel.swift
//  DejaViewPix
//

import AlbumAI
import Foundation
import Observation
import OSLog

/// The search screen's state: one explicit phase, plus the trace and cost of the last query.
@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle
        /// The status line describes the tool call that is running, not the model's chatter.
        case searching(status: String)
        case results(Outcome)
        case empty(Outcome)
        case failed(String)

        var outcome: Outcome? {
            switch self {
            case .results(let outcome), .empty(let outcome): outcome
            default: nil
            }
        }
    }

    struct Outcome: Equatable {
        /// Claude's summary. Nil once the user has edited the filters, because it no longer
        /// describes what is shown.
        var summary: String?
        /// Rebuilt from the searches that ran (or from the user's edits), never from the
        /// model's description.
        var filters: [AppliedFilters]
        var photos: [PhotoDetails]
        /// More photos matched than the search's limit.
        var hasMore: Bool

        var isEdited: Bool { summary == nil }
    }

    private(set) var phase: Phase = .idle
    private(set) var rounds: [ToolLoopRound] = []
    private(set) var metrics: QueryMetrics?
    /// True while edited filters are re-run on the device.
    private(set) var isUpdating = false

    private let model: ClaudeModel
    private let loop: ToolLoop
    private let tools: PhotoTools
    private let library = PhotoLibrary()

    /// Bumped by every search and edit, so a stale one never overwrites a newer result.
    private var generation = 0
    /// The last submission that ran to the end. The view's `.task(id:)` restarts when the
    /// screen reappears; this keeps a finished search from being paid for twice.
    private var finishedSubmission: UUID?
    private var editTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "DejaViewPix", category: "search")

    init(model: ClaudeModel = .haiku) {
        self.model = model
        tools = PhotoTools(library: library, geocoder: PlaceGeocoder(), timeZone: .current)
        loop = ToolLoop(
            client: ClaudeClient(model: model, apiKey: { try APIKeyStore.claude.load() }),
            tools: tools
        )
    }

    // MARK: - Searching with Claude

    /// Runs one query through the tool loop. Meant for `.task(id:)`: cancelling the task
    /// cancels the search, and the screen goes back to idle.
    func search(_ query: String, submission: UUID) async {
        guard submission != finishedSubmission else { return }
        editTask?.cancel()
        generation += 1
        let generation = generation
        rounds = []
        metrics = nil
        isUpdating = false
        phase = .searching(status: "Reading your request…")

        let system = SearchPrompt.system(now: .now, timeZone: .current)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: String
        do {
            let result = try await loop.run(
                query,
                system: system,
                onRound: { @MainActor [weak self] round in
                    guard let self, generation == self.generation else { return }
                    rounds.append(round)
                    Self.logTrace(round)
                },
                onToolStart: { @MainActor [weak self] start in
                    guard let self, generation == self.generation else { return }
                    phase = .searching(status: start.statusLine())
                }
            )
            let photos = await library.details(for: result.answer.photoIDs)
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            show(Outcome(summary: result.answer.summary, filters: result.answer.filters, photos: photos, hasMore: false))
            finishedSubmission = submission
            outcome = "ok, \(photos.count) photos"
        } catch {
            guard generation == self.generation else { return }
            if error is CancellationError || Task.isCancelled {
                phase = .idle
                outcome = "cancelled"
            } else {
                phase = .failed(error.localizedDescription)
                finishedSubmission = submission
                outcome = "error: \(error.localizedDescription)"
            }
        }

        // One usage line per query, failed ones included: they cost money too.
        let metrics = QueryMetrics(model: model.rawValue, rounds: rounds, latency: start.duration(to: clock.now))
        self.metrics = metrics
        Self.log.notice("search \(query, privacy: .private) · \(metrics.logLine(outcome: outcome), privacy: .public)")
    }

    // MARK: - Editing filters locally

    /// Removes a chip (`new == nil`) or replaces it, then re-runs the filters against the
    /// library directly. No model call: it's instant, free, and the user stays in control.
    func edit(_ old: FilterChip, to new: FilterChip?) {
        guard let current = phase.outcome else { return }
        let filters = current.filters.replacing(old, with: new)
        editTask?.cancel()
        generation += 1
        let generation = generation
        isUpdating = true

        editTask = Task {
            do {
                let result = try await tools.search(filters)
                let photos = await library.details(for: result.matches.map(\.id))
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                show(Outcome(summary: nil, filters: filters, photos: photos, hasMore: result.hasMore))
                Self.log.notice("filters edited · \(photos.count) photos · no model call")
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                phase = .failed(error.localizedDescription)
            }
            isUpdating = false
        }
    }

    private func show(_ outcome: Outcome) {
        phase = outcome.photos.isEmpty ? .empty(outcome) : .results(outcome)
    }

    private static func logTrace(_ round: ToolLoopRound) {
        if round.toolCalls.isEmpty {
            log.debug("round \(round.number) ended without a tool call (\(round.stopReason ?? "none")): \(round.text)")
        }
        for call in round.toolCalls {
            log.debug("""
                round \(round.number) \(call.name)(\(call.input.jsonString)) \
                → \(call.output.isError ? "ERROR " : "")\(call.output.content)
                """)
        }
    }
}
