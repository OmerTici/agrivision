import CoreML
import UIKit
import Vision

/// A single muzzle detection result.
struct MuzzleDetection {
    /// Normalized bounding box in Vision coordinates (origin bottom-left).
    let boundingBox: CGRect
    let confidence: Float
}

/// Loads the YOLO11n muzzle CoreML model and runs detections on live camera
/// frames or still images, and crops the detected muzzle.
final class MuzzleDetectorService {
    private var visionModel: VNCoreMLModel?

    init() {
        loadModel()
    }

    var isReady: Bool { visionModel != nil }

    private func loadModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // The .mlpackage is compiled into MuzzleDetector.mlmodelc inside the bundle.
        if let url = Bundle.main.url(forResource: "MuzzleDetector", withExtension: "mlmodelc") {
            do {
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                visionModel = try VNCoreMLModel(for: mlModel)
                return
            } catch {
                print("[MuzzleDetector] Failed to load compiled model: \(error)")
            }
        } else {
            print("[MuzzleDetector] MuzzleDetector.mlmodelc not found in bundle.")
        }
    }

    // MARK: - Detection

    /// Runs detection synchronously on a live camera pixel buffer.
    func detections(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> [MuzzleDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    /// Runs detection synchronously on a still image.
    func detections(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> [MuzzleDetection] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    private func perform(with handler: VNImageRequestHandler) -> [MuzzleDetection] {
        guard let visionModel else { return [] }

        var output: [MuzzleDetection] = []
        let request = VNCoreMLRequest(model: visionModel) { request, _ in
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
            output = results.map { obs in
                // Single-class YOLO pipelines report labels.first.confidence as a
                // constant 1.0; the real detection score is obs.confidence.
                MuzzleDetection(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        do {
            try handler.perform([request])
        } catch {
            print("[MuzzleDetector] Detection failed: \(error)")
        }
        return output
    }

    // MARK: - Cropping

    /// Crops the muzzle region out of a still image, with a little padding.
    func cropMuzzle(
        from cgImage: CGImage,
        boundingBox: CGRect,
        paddingFraction: CGFloat = 0.08
    ) -> UIImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        // Vision boxes use a bottom-left origin; convert to top-left for CGImage.
        var px = boundingBox.origin.x * w
        var py = (1 - boundingBox.origin.y - boundingBox.height) * h
        var pw = boundingBox.width * w
        var ph = boundingBox.height * h

        // Expand by padding, then clamp to image bounds.
        let padX = pw * paddingFraction
        let padY = ph * paddingFraction
        px -= padX
        py -= padY
        pw += padX * 2
        ph += padY * 2

        px = max(0, px)
        py = max(0, py)
        pw = min(pw, w - px)
        ph = min(ph, h - py)

        guard pw > 1, ph > 1,
              let cropped = cgImage.cropping(to: CGRect(x: px, y: py, width: pw, height: ph))
        else { return nil }

        return UIImage(cgImage: cropped)
    }
}

extension UIImage {
    /// Returns a CGImage redrawn so its orientation is `.up`, so Vision boxes
    /// map cleanly back onto it.
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.cgImage
    }
}
