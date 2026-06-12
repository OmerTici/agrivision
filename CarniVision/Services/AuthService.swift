import Foundation
import Supabase

/// Minimal identity surface the app needs from the auth backend.
struct AuthIdentity: Equatable {
    let userID: String
    let accessToken: String
}

/// Seam that lets tests substitute the Supabase auth client.
protocol AuthBackend {
    func signIn(email: String, password: String) async throws -> AuthIdentity
    func signUp(email: String, password: String) async throws -> AuthIdentity
    func signOut() async throws
    /// Returns a persisted session if the SDK restored one at launch.
    func restoreSession() async -> AuthIdentity?
}

/// Production backend backed by the real SupabaseClient.
struct SupabaseAuthBackend: AuthBackend {
    let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    private func identity(from session: Session) -> AuthIdentity {
        AuthIdentity(userID: session.user.id.uuidString, accessToken: session.accessToken)
    }

    func signIn(email: String, password: String) async throws -> AuthIdentity {
        let session = try await client.auth.signIn(email: email, password: password)
        return identity(from: session)
    }

    func signUp(email: String, password: String) async throws -> AuthIdentity {
        let response = try await client.auth.signUp(email: email, password: password)
        guard let session = response.session else {
            // Email-confirmation projects return no session until confirmed.
            throw NSError(domain: "auth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Check your email to confirm your account."
            ])
        }
        return AuthIdentity(userID: session.user.id.uuidString, accessToken: session.accessToken)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    func restoreSession() async -> AuthIdentity? {
        guard let session = try? await client.auth.session else { return nil }
        return identity(from: session)
    }
}

/// Owns auth state for the UI. `identity != nil` means the user is signed in.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    var accessToken: String? { identity?.accessToken }
    var userID: String? { identity?.userID }

    private let backend: AuthBackend

    init(backend: AuthBackend = SupabaseAuthBackend()) {
        self.backend = backend
    }

    /// Restore a persisted session at launch (call from the app entry point).
    func bootstrap() async {
        if let restored = await backend.restoreSession() {
            identity = restored
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            identity = try await backend.signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            identity = try await backend.signUp(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        do {
            try await backend.signOut()
            identity = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
