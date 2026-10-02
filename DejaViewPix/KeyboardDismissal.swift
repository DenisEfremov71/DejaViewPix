//
//  KeyboardDismissal.swift
//  DejaViewPix
//

import SwiftUI

extension View {
    /// A multi-line (`axis: .vertical`) text field inserts a newline on Return and never
    /// calls `onSubmit`, so the keyboard can't be closed. This makes Return submit instead:
    /// the newline is removed and `action` runs.
    func submitOnReturn(_ text: Binding<String>, action: @escaping () -> Void) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            guard newValue.contains("\n") else { return }
            text.wrappedValue = newValue.replacingOccurrences(of: "\n", with: "")
            action()
        }
    }

    /// Tapping outside the text field closes the keyboard. Buttons inside still get their taps.
    func dismissesKeyboardOnTap(_ focus: FocusState<Bool>.Binding) -> some View {
        contentShape(Rectangle())
            .onTapGesture { focus.wrappedValue = false }
    }
}
