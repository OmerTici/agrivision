import CoreML
import UIKit
import Vision

/// A single cow detection from the live gate (COCO YOLO11s, "cow" class).
struct CowDetection {
    let boundingBox: CGRect
    let confidence: Float
}

/// Loads the stock COCO CoreML detector and returns only detections whose top
/// class is "cow"; person, sheep, horse, dog, and everything else are discarded.
final class CowDetectorService {
    private var visionModel: VNCoreMLModel?

    init() {
        loadModel()
    }

    var isReady: Bool { visionModel != nil }

    private func loadModel() {
        let config = MLModelConfiguration()
        // CPU only: this YOLO export produces wrong/garbage scores on the iPhone
        // Neural Engine (the .all path), so cows scored ~0 on device. CPU matches
        // the verified offline behavior. YOLO11s on CPU stays realtime for the
        // live gate; ~3.5x the compute of a nano model, so watch latency/thermals.
        config.computeUnits = .cpuOnly

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
                // obs.confidence is the detection score; the per-label confidence
                // is a separate value we don't gate on.
                return CowDetection(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
        }
        // Letterbox (aspect-preserving) to match how YOLO was trained. scaleFill
        // stretched the phone's portrait frame into a square, distorting the cow
        // and dropping real cows below threshold; scaleFit keeps proportions.
        request.imageCropAndScaleOption = .scaleFit

        do {
            try handler.perform([request])
        } catch {
            print("[CowDetector] Detection failed: \(error)")
        }
        return output
    }

    private static func isCow(_ observation: VNRecognizedObjectObservation) -> Bool {
        // Accept only when the top class is COCO "cow"; person/sheep/horse/dog/etc.
        // are rejected so they can't trigger the capture gate.
        guard let top = observation.labels.max(by: { $0.confidence < $1.confidence }) else {
            return false
        }
        return top.identifier.lowercased() == "cow"
    }
}
