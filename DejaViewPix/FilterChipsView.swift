//
//  FilterChipsView.swift
//  DejaViewPix
//

import AlbumAI
import SwiftUI

/// What the app understood, as chips. Tapping a chip edits it; the × removes it. Either way
/// the search re-runs on the device without calling the model.
struct FilterChipsView: View {
    let chips: [FilterChip]
    let onEdit: (FilterChip, FilterChip?) -> Void

    @State private var editingDates: FilterChip?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(chips, id: \.self) { chip in
                chipView(chip)
            }
        }
        .sheet(item: $editingDates) { chip in
            DateRangeEditor(chip: chip) { onEdit(chip, $0) }
        }
    }

    private func chipView(_ chip: FilterChip) -> some View {
        HStack(spacing: 6) {
            Menu {
                editActions(for: chip)
                Button("Remove", systemImage: "xmark", role: .destructive) { onEdit(chip, nil) }
            } label: {
                Label(chip.label(), systemImage: chip.systemImage)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHint("Edit or remove this filter")

            Button {
                onEdit(chip, nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(chip.label())")
        }
        .font(.subheadline)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.tint.opacity(0.12), in: .capsule)
    }

    @ViewBuilder
    private func editActions(for chip: FilterChip) -> some View {
        switch chip {
        case .dates:
            Button("Change Dates…", systemImage: "calendar") { editingDates = chip }
        case let .place(name, circle):
            Picker("Search Radius", selection: Binding(
                get: { circle.radiusMeters },
                set: { radius in
                    var wider = circle
                    wider.radiusMeters = radius
                    onEdit(chip, .place(name: name, circle: wider))
                }
            )) {
                ForEach(Self.radii(including: circle.radiusMeters), id: \.self) { radius in
                    Text(FilterChip.radiusText(radius)).tag(radius)
                }
            }
        case .mediaType(let type):
            let other = type == "video" ? "photo" : "video"
            Button(other == "video" ? "Videos Instead" : "Photos Instead", systemImage: other == "video" ? "video" : "photo") {
                onEdit(chip, .mediaType(other))
            }
        case .favorites, .album, .oldestFirst:
            EmptyView()
        }
    }

    /// Preset radii, plus the current one if the model picked something else.
    private static func radii(including current: Double) -> [Double] {
        Array(Set([300, 1_500, 5_000, 15_000, 50_000, 200_000, current])).sorted()
    }
}

extension FilterChip: @retroactive Identifiable {
    public var id: Self { self }
}

/// Edits a dates chip. Both ends are whole days in the user's calendar, inclusive.
private struct DateRangeEditor: View {
    let chip: FilterChip
    let onSave: (FilterChip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date

    init(chip: FilterChip, onSave: @escaping (FilterChip) -> Void) {
        self.chip = chip
        self.onSave = onSave
        var from: String?
        var to: String?
        if case let .dates(start, end) = chip {
            from = start
            to = end
        }
        let today = Calendar.current.startOfDay(for: .now)
        _from = State(initialValue: from.flatMap(Self.date) ?? to.flatMap(Self.date) ?? today)
        _to = State(initialValue: to.flatMap(Self.date) ?? today)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("Dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onSave(.dates(from: Self.day(from), to: Self.day(max(from, to))))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// YYYY-MM-DD in the user's calendar, matching what the tools take.
    nonisolated private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    nonisolated private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Lays children out in rows, wrapping when a row is full. A child wider than the row gets
/// the full width, so chips stay readable at the largest Dynamic Type sizes.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}
