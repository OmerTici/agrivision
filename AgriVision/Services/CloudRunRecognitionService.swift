import Foundation

/// Lifecycle of the scale-to-zero embedder as the app understands it.
enum ServerStatus { case unknown, connecting, online, offline }

/// Talks to the Cloud Run embedder over multipart/form-data with a Bearer JWT.
@MainActor
final class CloudRunRecognitionService: ObservableObject, RecognitionService {
    /// Drives the status pill and the camera readiness gate.
    @Published var status: ServerStatus = .unknown
    /// True once /health reports the model is loaded.
    var isReady: Bool { status == .online }

    private let baseURL: URL
    private let session: URLSession
    /// Returns a guaranteed-fresh access token at call time (the SDK refreshes if needed).
    private let tokenProvider: () async -> String?

    /// Cold-start budget for the first network call.
    private let coldStartTimeout: TimeInterval = 90

    /// Injected so tests can advance time; production uses the wall clock.
    private let now: () -> Date
    /// Skip re-pinging if we confirmed online within this window (< container idle timeout).
    private let debounceWindow: TimeInterval = 120
    /// Timestamp of the last confirmed-online /health.
    private var lastOnlineCheck: Date?

    init(baseURL: URL, session: URLSession = .shared,
         tokenProvider: @escaping () async -> String?,
         now: @escaping () -> Date = Date.init) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.now = now
    }

    func warmUp() async {
        // Debounce: if we confirmed online recently, skip the network entirely.
        if status == .online, let last = lastOnlineCheck,
           now().timeIntervalSince(last) < debounceWindow { return }

        status = .connecting
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = coldStartTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = .offline
                return
            }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            if health.modelLoaded {
                status = .online
                lastOnlineCheck = now()
            } else {
                status = .offline
            }
        } catch {
            status = .offline
        }
    }

    func identify(jpegData: Data) async throws -> IdentifyResult {
        guard let token = await tokenProvider() else { throw RecognitionError.notAuthenticated }
        var form = MultipartFormData()
        form.appendFile(name: "image", filename: "muzzle.jpg", mimeType: "image/jpeg", data: jpegData)
        let request = makeRequest(path: "identify", form: form, token: token)
        return try await send(request, decode: IdentifyResult.self)
    }

    func enroll(animalID: String, muzzleJpegs: [Data], fullJpeg: Data?) async throws -> EnrollResult {
        guard let token = await tokenProvider() else { throw RecognitionError.notAuthenticated }
        var form = MultipartFormData()
        form.appendField(name: "animal_id", value: animalID)
        for (index, jpeg) in muzzleJpegs.enumerated() {
            form.appendFile(name: "images", filename: "muzzle_\(index).jpg",
                            mimeType: "image/jpeg", data: jpeg)
        }
        if let fullJpeg {
            form.appendFile(name: "full_images", filename: "full.jpg",
                            mimeType: "image/jpeg", data: fullJpeg)
        }
        let request = makeRequest(path: "enroll", form: form, token: token)
        return try await send(request, decode: EnrollResult.self)
    }

    private func makeRequest(path: String, form: MultipartFormData, token: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = coldStartTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalizedBody()
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RecognitionError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RecognitionError.http(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecognitionError.http(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RecognitionError.decoding(error)
        }
    }
}

/// /health response shape.
private struct HealthResponse: Decodable {
    let status: String
    let modelLoaded: Bool
    enum CodingKeys: String, CodingKey {
        case status
        case modelLoaded = "model_loaded"
    }
}
