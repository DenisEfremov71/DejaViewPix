//
//  PhotoAccessViews.swift
//  DejaViewPix
//

import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Shown before the system prompt, so the user knows why access is needed and what leaves
/// the device.
struct PhotoAccessIntroView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                Text("Find photos by describing them")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                point(
                    "text.magnifyingglass",
                    "Search in your own words",
                    "Try “photos from Whistler last winter” or “my favorite videos”."
                )
                point(
                    "lock",
                    "Your photos stay on your iPhone",
                    "Claude sees what you type, plus the IDs, dates and distances of matching photos. Never the photos themselves."
                )
                point(
                    "hand.raised",
                    "You decide what to share",
                    "Allow your whole library or just a selection. You can change it in Settings at any time."
                )
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    private func point(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Denied or restricted: nothing to search, and the screen says what the user can do.
struct PhotoAccessBlockedView: View {
    let status: PHAuthorizationStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        if status == .restricted {
            ContentUnavailableView(
                "Photo Access Is Restricted",
                systemImage: "lock.shield",
                description: Text("A device setting, such as Screen Time or a profile, blocks photo access, so it can't be changed here.")
            )
        } else {
            ContentUnavailableView {
                Label("Photo Access Is Off", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("Deja View Pix can only search photos you let it see. Turn on access in Settings, then come back.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Limited access works, but only on the photos the user picked. Say so, and offer to pick
/// more.
struct LimitedAccessBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "photo.badge.checkmark")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Searching only the photos you selected.")
                Button("Select More Photos", action: presentLimitedLibraryPicker)
                    .fontWeight(.semibold)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 10))
    }

    private func presentLimitedLibraryPicker() {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

#Preview("Intro") {
    PhotoAccessIntroView {}
}

#Preview("Denied") {
    PhotoAccessBlockedView(status: .denied)
}
