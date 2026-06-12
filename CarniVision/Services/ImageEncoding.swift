import UIKit

enum ImageEncoding {
    /// JPEG-encodes a muzzle crop at quality 0.85 (native size; crops are small).
    static func muzzleJPEG(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.85)
    }

    /// Downscales to <= maxDimension on the longest side, then JPEG-encodes at 0.85.
    static func fullBodyJPEG(_ image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        downscaled(image, maxDimension: maxDimension).jpegData(compressionQuality: 0.85)
    }

    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
