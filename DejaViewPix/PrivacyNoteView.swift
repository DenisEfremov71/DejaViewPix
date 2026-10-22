//
//  PrivacyNoteView.swift
//  DejaViewPix
//

import SwiftUI

/// What leaves the device during a search, and what never does. Kept in step with what
/// the tools actually send (see PhotoTools in the AlbumAI package).
struct PrivacyNoteView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    item("photo.on.rectangle", "Your photos never leave your iPhone", """
                        Images and videos are never uploaded, and nothing looks at their contents. \
                        Thumbnails are drawn on the device.
                        """)
                }

                Section("Sent to Claude (Anthropic) during a search") {
                    item("text.bubble", "What you type", "Your search, today's date and your time zone.")
                    item("list.bullet.rectangle", "Metadata of matching photos", """
                        For each photo a search finds: its ID, the date and time it was taken, \
                        its distance from a place you named, and whether it's a video or a favorite. \
                        Album names and counts, when you search an album.
                        """)
                    item("mappin.and.ellipse", "Places you name", """
                        Their names and coordinates. Place names are looked up with Apple Maps.
                        """)
                }

                Section("Not sent") {
                    item("location.slash", "Where your photos were taken", """
                        Coordinates of your photos stay on the device; only the distance from \
                        the place you searched for is shared.
                        """)
                    item("person.crop.circle.badge.xmark", "Who is in them", "No faces, people, captions or image contents.")
                }

                Section("Your API key") {
                    item("key", "Stored in the Keychain", """
                        Kept on this iPhone only: never synced to iCloud or moved to another \
                        device, and never written to files or logs. It's sent only to \
                        api.anthropic.com, with each request.
                        """)
                }

                Section {
                    item("slider.horizontal.3", "Editing filters stays on your iPhone", """
                        Removing or changing a filter searches your library directly. Nothing is sent.
                        """)
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func item(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PrivacyNoteView()
}
