import CoreML
import UIKit
import Vision

/// A single cattle face detection (fine-tuned YOLO11n).
struct CowFaceDetection {
    let boundingBox: CGRect
    let confidence: Float
}

/// Loads the cow-face CoreML model and returns detections whose top class
/// is the cow face; detections of any other class are discarded.
final class CowFaceDetectorService {
    private var visionModel: VNCoreMLModel?

    init() {
        loadModel()
    }

    var isReady: Bool { visionModel != nil }

    private func loadModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let url = Bundle.main.url(forResource: "CowFaceDetector", withExtension: "mlmodelc") {
            do {
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                visionModel = try VNCoreMLModel(for: mlModel)
                return
            } catch {
                print("[CowFaceDetector] Failed to load compiled model: \(error)")
            }
        } else {
            print("[CowFaceDetector] CowFaceDetector.mlmodelc not found in bundle.")
        }
    }

    func detections(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> [CowFaceDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    func detections(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> [CowFaceDetection] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    private func perform(with handler: VNImageRequestHandler) -> [CowFaceDetection] {
        guard let visionModel else { return [] }

        var output: [CowFaceDetection] = []
        let request = VNCoreMLRequest(model: visionModel) { request, _ in
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
            output = results.compactMap { obs in
                guard Self.isCowFace(obs) else { return nil }
                // Single-class YOLO pipelines report labels.first.confidence as a
                // constant 1.0; the real detection score is obs.confidence.
                return CowFaceDetection(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        do {
            try handler.perform([request])
        } catch {
            print("[CowFaceDetector] Detection failed: \(error)")
        }
        return output
    }

    private static func isCowFace(_ observation: VNRecognizedObjectObservation) -> Bool {
        // No labels at all only happens with single-class models; accept those.
        guard let top = observation.labels.max(by: { $0.confidence < $1.confidence }) else {
            return true
        }
        let identifier = top.identifier.lowercased().replacingOccurrences(of: "-", with: "_")
        // Accept only the cow-face class ("0" covers unnamed single-class exports);
        // any other top class — sheep, dog, whatever a future model adds — is rejected.
        return identifier.contains("cow") || identifier == "0"
    }

    /// Crops the muzzle region from a still photo using the lower portion of a face box.
    func cropMuzzleFromFace(
        from cgImage: CGImage,
        faceBox: CGRect,
        paddingFraction: CGFloat = 0.06
    ) -> UIImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        let faceX = faceBox.origin.x * w
        let faceY = (1 - faceBox.origin.y - faceBox.height) * h
        let faceW = faceBox.width * w
        let faceH = faceBox.height * h

        let muzzleH = faceH * 0.38
        let muzzleW = faceW * 0.58
        let centerX = faceX + faceW * 0.5
        let centerY = faceY + faceH * 0.78

        var px = centerX - muzzleW * 0.5
        var py = centerY - muzzleH * 0.5
        var pw = muzzleW
        var ph = muzzleH

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
