import Foundation

protocol RecognitionService {
    /// Pings the embedder to start a container (cold-start budget); updates `isReady`.
    func warmUp() async
    func identify(jpegData: Data) async throws -> IdentifyResult
    func enroll(animalID: String, muzzleJpegs: [Data], fullJpeg: Data?) async throws -> EnrollResult
}

/// Canned responses for previews and unit tests; no network.
@MainActor
final class MockRecognitionService: ObservableObject, RecognitionService {
    @Published var isReady = true
    var identifyResult: IdentifyResult
    var enrollResult: EnrollResult

    init(
        identifyResult: IdentifyResult = IdentifyResult(
            decision: "identified", animalId: "mock-uuid", name: "Daisy",
            score: 0.91, margin: 0.22, candidates: []
        ),
        enrollResult: EnrollResult = EnrollResult(enrolledCount: 5, fullImagesStored: 1)
    ) {
        self.identifyResult = identifyResult
        self.enrollResult = enrollResult
    }

    func warmUp() async { isReady = true }
    func identify(jpegData: Data) async throws -> IdentifyResult { identifyResult }
    func enroll(animalID: String, muzzleJpegs: [Data], fullJpeg: Data?) async throws -> EnrollResult {
        enrollResult
    }
}
