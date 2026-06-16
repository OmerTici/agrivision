import Foundation

struct Candidate: Decodable, Equatable {
    let animalId: String
    let name: String?
    let sim: Double

    enum CodingKeys: String, CodingKey {
        case animalId = "animal_id"
        case name
        case sim
    }
}

struct IdentifyResult: Decodable, Equatable {
    let decision: String      // "identified" | "unknown"
    let animalId: String?
    let name: String?
    let score: Double
    let margin: Double
    let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case decision
        case animalId = "animal_id"
        case name
        case score
        case margin
        case candidates
    }

    var isIdentified: Bool { decision == "identified" }
}

struct EnrollResult: Decodable, Equatable {
    let enrolledCount: Int
    let fullImagesStored: Int

    enum CodingKeys: String, CodingKey {
        case enrolledCount = "enrolled_count"
        case fullImagesStored = "full_images_stored"
    }
}

enum RecognitionError: Error, LocalizedError {
    case notAuthenticated
    case http(status: Int, body: String)
    case transport(Error)
    case decoding(Error)
    case encoding

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        case let .http(status, _): return "Server error (\(status))."
        case .transport: return "Network unavailable."
        case .decoding: return "Unexpected server response."
        case .encoding: return "Could not prepare the image."
        }
    }
}
