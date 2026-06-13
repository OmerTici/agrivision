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
    /// Updates the signed-in user's email. Projects with email confirmation
    /// enabled send a verification link and defer the change until confirmed.
    func updateEmail(_ email: String) async throws
    /// Emails the signed-in user a 6-digit reauthentication code. Required before
    /// `updatePassword` when the project enforces secure password change.
    func sendReauthenticationCode() async throws
    /// Updates the signed-in user's password, confirming identity with the
    /// `nonce` (the emailed reauthentication code).
    func updatePassword(_ password: String, nonce: String) async throws
    /// Returns a persisted session if the SDK restored one at launch.
    func restoreSession() async -> AuthIdentity?
    /// Emits identity updates as the SDK's session changes (refresh / sign-in / sign-out).
    /// `nil` means the user is now signed out. Default: an empty stream (no updates).
    func identityUpdates() -> AsyncStream<AuthIdentity?>
    /// Completes a sign-in from a deep link (email confirmation / magic link).
    /// Returns the new identity, or nil if the URL carried no auth payload.
    func handleOpenURL(_ url: URL) async throws -> AuthIdentity?
}

extension AuthBackend {
    func identityUpdates() -> AsyncStream<AuthIdentity?> {
        AsyncStream { $0.finish() }
    }

    func handleOpenURL(_ url: URL) async throws -> AuthIdentity? { nil }
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

    func updateEmail(_ email: String) async throws {
        try await client.auth.update(user: UserAttributes(email: email))
    }

    func sendReauthenticationCode() async throws {
        try await client.auth.reauthenticate()
    }

    func updatePassword(_ password: String, nonce: String) async throws {
        try await client.auth.update(user: UserAttributes(password: password, nonce: nonce))
    }

    /// Exchanges the deep link's auth payload (PKCE `code`) for a session. The
    /// authStateChanges stream then emits `.signedIn`, but we also return the
    /// identity so the caller can update the UI immediately.
    func handleOpenURL(_ url: URL) async throws -> AuthIdentity? {
        let session = try await client.auth.session(from: url)
        return identity(from: session)
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

    /// Entry point for `onOpenURL`: finishes a deep-link sign-in (email
    /// confirmation / magic link). On success the user lands signed-in without
    /// retyping credentials. Ignores non-auth URLs (handleOpenURL returns nil).
    func handleDeepLink(_ url: URL) async {
        errorMessage = nil
        do {
            if let restored = try await backend.handleOpenURL(url) {
                identity = restored
            }
        } catch {
            errorMessage = error.localizedDescription
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

    /// Updates the account email. Returns true on success so the caller can
    /// confirm to the user (a verification email may still be pending).
    func updateEmail(_ email: String) async -> Bool {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.updateEmail(email)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Emails the signed-in user a 6-digit code to confirm a password change.
    /// Returns true once the code is sent. Does not toggle `isWorking` so the
    /// caller can show a dedicated "sending" state separate from the save button.
    func sendPasswordChangeCode() async -> Bool {
        errorMessage = nil
        do {
            try await backend.sendReauthenticationCode()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Updates the account password, confirming the user with the emailed
    /// reauthentication `code`. Call `sendPasswordChangeCode` first. Returns true
    /// on success.
    func updatePassword(new: String, code: String) async -> Bool {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.updatePassword(new, nonce: code)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
