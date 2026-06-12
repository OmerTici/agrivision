import Foundation
import SwiftUI
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
    /// Emits identity updates as the SDK's session changes (refresh / sign-in / sign-out).
    /// `nil` means the user is now signed out. Default: an empty stream (no updates).
    func identityUpdates() -> AsyncStream<AuthIdentity?>
}

extension AuthBackend {
    func identityUpdates() -> AsyncStream<AuthIdentity?> {
        AsyncStream { $0.finish() }
    }
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
                NSLocalizedDescriptionKey: LanguageManager.shared.t("auth.confirmEmail")
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

    /// Bridges supabase-swift's `authStateChanges` to identity updates. The SDK
    /// refreshes the access token transparently and emits `.tokenRefreshed`, so
    /// subscribing here keeps `AuthService.identity` from going stale.
    func identityUpdates() -> AsyncStream<AuthIdentity?> {
        AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .signedIn, .tokenRefreshed:
                        if let session { continuation.yield(identity(from: session)) }
                    case .signedOut:
                        continuation.yield(nil)
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
    /// Long-lived subscription to SDK auth-state changes; cancelled on deinit.
    private var authStateTask: Task<Void, Never>?

    init(backend: AuthBackend = SupabaseAuthBackend()) {
        self.backend = backend
    }

    deinit {
        authStateTask?.cancel()
    }

    /// Restore a persisted session at launch (call from the app entry point).
    func bootstrap() async {
        if let restored = await backend.restoreSession() {
            identity = restored
        }
        observeAuthState()
    }

    /// Keeps `identity` in sync with the SDK's session (token refresh, sign-in, sign-out)
    /// so a stale snapshot can never linger after the access token rotates.
    private func observeAuthState() {
        guard authStateTask == nil else { return }
        authStateTask = Task { [weak self] in
            guard let updates = self?.backend.identityUpdates() else { return }
            for await identity in updates {
                self?.identity = identity
            }
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
        errorMessage = nil
        do {
            try await backend.signOut()
            identity = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
