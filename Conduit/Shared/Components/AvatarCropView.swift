//
//  AvatarCropView.swift
//  Conduit
//
//  Move-and-scale cropper for the agent avatar: pinch to zoom, drag to choose
//  the focus, a circular viewport shows exactly what the avatar will be. The
//  geometry lives in AvatarCrop (pure, unit-tested); this view renders it and
//  produces the cropped square image on confirm.
//

import SwiftUI

struct AvatarCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxZoom: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height) - 48
                let liveZoom = clampZoom(zoom * pinch)
                let liveOffset = clampOffset(
                    CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                    diameter: diameter, zoom: liveZoom
                )
                let fill = AvatarCrop.baseFillScale(imageSize: image.size, diameter: diameter)

                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: image.size.width * fill * liveZoom,
                            height: image.size.height * fill * liveZoom
                        )
                        .offset(liveOffset)
                        .mask {
                            // Dim outside the viewport but keep the image visible
                            // through it: full image at low opacity + the circle.
                            ZStack {
                                Rectangle().opacity(0.35)
                                Circle().frame(width: diameter, height: diameter)
                            }
                        }

                    Circle()
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                }
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                zoom = clampZoom(zoom * value)
                                offset = clampOffset(offset, diameter: diameter, zoom: zoom)
                            },
                        DragGesture()
                            .updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                offset = clampOffset(
                                    CGSize(
                                        width: offset.width + value.translation.width,
                                        height: offset.height + value.translation.height
                                    ),
                                    diameter: diameter, zoom: zoom
                                )
                            }
                    )
                )
                .navigationTitle("Move and Scale")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.AddAgent.cropCancelButton)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Choose") {
                            onCrop(cropped(diameter: diameter))
                            dismiss()
                        }
                        .accessibilityIdentifier(AccessibilityID.AddAgent.cropChooseButton)
                    }
                }
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
        .interactiveDismissDisabled()
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(1, value), Self.maxZoom)
    }

    private func clampOffset(_ value: CGSize, diameter: CGFloat, zoom: CGFloat) -> CGSize {
        let limit = AvatarCrop.maxOffset(imageSize: image.size, diameter: diameter, zoom: zoom)
        return CGSize(
            width: min(max(-limit.width, value.width), limit.width),
            height: min(max(-limit.height, value.height), limit.height)
        )
    }

    /// Render the square under the viewport from the ORIGINAL image (drawing
    /// via UIImage respects orientation, so no CGImage-orientation gymnastics).
    private func cropped(diameter: CGFloat) -> UIImage {
        let rect = AvatarCrop.cropRect(
            imageSize: image.size, diameter: diameter, zoom: zoom, offset: offset
        )
        let side = min(rect.width, 1024)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let target = CGSize(width: side, height: side)
        let factor = side / rect.width
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(
                x: -rect.minX * factor,
                y: -rect.minY * factor,
                width: image.size.width * factor,
                height: image.size.height * factor
            ))
        }
    }
}
