import CoreML
import UIKit
import Vision

/// A single cow detection result (COCO YOLO11n, class: cow).
struct CowDetection {
    let boundingBox: CGRect
    let confidence: Float
}

/// Loads the COCO YOLO11n CoreML model and returns cow detections only.
final class CowDetectorService {
    private var visionModel: VNCoreMLModel?

    init() {
        loadModel()
    }

    var isReady: Bool { visionModel != nil }

    private func loadModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let url = Bundle.main.url(forResource: "CowDetector", withExtension: "mlmodelc") {
            do {
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                visionModel = try VNCoreMLModel(for: mlModel)
                return
            } catch {
                print("[CowDetector] Failed to load compiled model: \(error)")
            }
        } else {
            print("[CowDetector] CowDetector.mlmodelc not found in bundle.")
        }
    }

    func detections(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> [CowDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    func detections(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> [CowDetection] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        return perform(with: handler)
    }

    private func perform(with handler: VNImageRequestHandler) -> [CowDetection] {
        guard let visionModel else { return [] }

        var output: [CowDetection] = []
        let request = VNCoreMLRequest(model: visionModel) { request, _ in
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
            output = results.compactMap { obs in
                guard Self.isCow(obs) else { return nil }
                return CowDetection(
                    boundingBox: obs.boundingBox,
                    confidence: obs.labels.first?.confidence ?? obs.confidence
                )
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        do {
            try handler.perform([request])
        } catch {
            print("[CowDetector] Detection failed: \(error)")
        }
        return output
    }

    private static func isCow(_ observation: VNRecognizedObjectObservation) -> Bool {
        if let label = observation.labels.first?.identifier.lowercased(), label == "cow" {
            return true
        }
        return observation.labels.contains { $0.identifier.lowercased() == "cow" }
    }
}
