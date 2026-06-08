//
//  RoutePickerView.swift
//  Conduit
//
//  SwiftUI wrapper over `AVRoutePickerView` — the only audio-route UI Apple
//  ships (AirPlay / Bluetooth / speaker picker), with no SwiftUI equivalent. Used
//  on the in-call screen so the user can switch routes by hand mid-call.
//

import AVKit
import SwiftUI

struct RoutePickerView: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = tint
        picker.tintColor = tint
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = tint
        uiView.tintColor = tint
    }
}
