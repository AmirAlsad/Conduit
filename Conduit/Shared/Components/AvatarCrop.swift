//
//  AvatarCrop.swift
//  Conduit
//
//  The pure geometry behind the move-and-scale avatar cropper: given how the
//  image is displayed (zoom + pan over an aspect-filled base), which square of
//  the ORIGINAL image sits under the circular viewport? Kept free of SwiftUI so
//  the math is unit-tested at simulator speed; AvatarCropView renders it.
//

import CoreGraphics

enum AvatarCrop {
    /// The scale that aspect-fills `imageSize` into a `diameter`-sided square.
    static func baseFillScale(imageSize: CGSize, diameter: CGFloat) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return diameter / min(imageSize.width, imageSize.height)
    }

    /// The crop square in image coordinates for a display state of `zoom`
    /// (≥ 1, on top of the aspect-fill base) and `offset` (the image's pan,
    /// in view points). Origin-clamped so the rect never leaves the image.
    static func cropRect(
        imageSize: CGSize,
        diameter: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) -> CGRect {
        let k = baseFillScale(imageSize: imageSize, diameter: diameter) * zoom
        guard k > 0 else { return CGRect(origin: .zero, size: imageSize) }
        let side = diameter / k
        var origin = CGPoint(
            x: (imageSize.width - side) / 2 - offset.width / k,
            y: (imageSize.height - side) / 2 - offset.height / k
        )
        origin.x = min(max(0, origin.x), max(0, imageSize.width - side))
        origin.y = min(max(0, origin.y), max(0, imageSize.height - side))
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    /// The pan limit (per axis, view points) that keeps the viewport inside the
    /// displayed image — the drag clamp.
    static func maxOffset(imageSize: CGSize, diameter: CGFloat, zoom: CGFloat) -> CGSize {
        let k = baseFillScale(imageSize: imageSize, diameter: diameter) * zoom
        return CGSize(
            width: max(0, (imageSize.width * k - diameter) / 2),
            height: max(0, (imageSize.height * k - diameter) / 2)
        )
    }
}
