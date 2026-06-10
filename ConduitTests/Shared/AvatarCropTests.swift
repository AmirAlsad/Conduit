//
//  AvatarCropTests.swift
//  ConduitTests
//
//  The move-and-scale cropper's geometry: which square of the original image
//  sits under the circular viewport for a given zoom/pan.
//

import CoreGraphics
import Testing
@testable import Conduit

struct AvatarCropTests {

    // A 4:3 landscape image, 200pt viewport.
    private let landscape = CGSize(width: 2000, height: 1500)
    private let diameter: CGFloat = 200

    @Test func aspectFillScalesToTheShorterSide() {
        // 1500 (short side) must fill 200 → scale 200/1500.
        let scale = AvatarCrop.baseFillScale(imageSize: landscape, diameter: diameter)
        #expect(abs(scale - 200.0 / 1500.0) < 0.0001)
    }

    @Test func unzoomedCenteredCropIsTheMiddleSquare() {
        let rect = AvatarCrop.cropRect(imageSize: landscape, diameter: diameter, zoom: 1, offset: .zero)
        // At zoom 1 the crop side equals the short image side, centered horizontally.
        #expect(abs(rect.width - 1500) < 0.001)
        #expect(abs(rect.height - 1500) < 0.001)
        #expect(abs(rect.minX - 250) < 0.001)
        #expect(rect.minY == 0)
    }

    @Test func zoomShrinksTheCropAroundTheCenter() {
        let rect = AvatarCrop.cropRect(imageSize: landscape, diameter: diameter, zoom: 2, offset: .zero)
        #expect(abs(rect.width - 750) < 0.001)
        #expect(abs(rect.midX - 1000) < 0.001) // still centered
        #expect(abs(rect.midY - 750) < 0.001)
    }

    @Test func panMovesTheCropOppositeTheImageOffset() {
        // Dragging the image right (positive offset) reveals more of its left side.
        let right = AvatarCrop.cropRect(
            imageSize: landscape, diameter: diameter, zoom: 1,
            offset: CGSize(width: 20, height: 0)
        )
        let centered = AvatarCrop.cropRect(imageSize: landscape, diameter: diameter, zoom: 1, offset: .zero)
        #expect(right.minX < centered.minX)
    }

    @Test func cropNeverLeavesTheImage() {
        let rect = AvatarCrop.cropRect(
            imageSize: landscape, diameter: diameter, zoom: 1.5,
            offset: CGSize(width: 10_000, height: -10_000)
        )
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= landscape.width)
        #expect(rect.maxY <= landscape.height)
    }

    @Test func maxOffsetIsZeroOnTheSnugAxisAtZoomOne() {
        // At zoom 1 the short axis fits exactly — no pan room there.
        let limit = AvatarCrop.maxOffset(imageSize: landscape, diameter: diameter, zoom: 1)
        #expect(limit.height == 0)
        #expect(limit.width > 0)
    }

    @Test func panLimitGrowsWithZoom() {
        let z1 = AvatarCrop.maxOffset(imageSize: landscape, diameter: diameter, zoom: 1)
        let z2 = AvatarCrop.maxOffset(imageSize: landscape, diameter: diameter, zoom: 2)
        #expect(z2.width > z1.width)
        #expect(z2.height > z1.height)
    }
}
