//
//  BrandMark.swift
//  Conduit
//
//  The Conduit app icon rendered as a small badge. Shown centered at the top of
//  each main tab (just below the dynamic island) via `brandMarkToolbar()`. Drawn
//  from the same artwork as the app icon (the `BrandMark` asset), so the two stay
//  in sync.
//

import SwiftUI

struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Pins the Conduit brand mark to the top-center of the navigation bar
    /// (just below the dynamic island). Applied to the main tab roots.
    func brandMarkToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                BrandMark()
            }
        }
    }
}

#Preview {
    NavigationStack {
        Color.clear
            .navigationTitle("Recents")
            .brandMarkToolbar()
    }
}
