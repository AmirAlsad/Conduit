//
//  UIImage+Avatar.swift
//  Conduit
//
//  Downscales a picked photo to an avatar-sized JPEG before it's stored on the
//  agent (SwiftData external storage) and written into the system contact — a
//  full-resolution camera photo would bloat both for no visible gain at the sizes
//  the avatar is ever shown.
//

import UIKit

extension UIImage {
    func conduitAvatarData(maxDimension: CGFloat = 512, quality: CGFloat = 0.8) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Redraw with `.up` orientation at a crop-friendly working size, so the
    /// cropper's geometry (`AvatarCrop`) can treat `size` as plain pixels
    /// without EXIF-orientation gymnastics.
    func normalizedUp(maxDimension: CGFloat = 2048) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
