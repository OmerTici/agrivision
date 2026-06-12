import XCTest
@testable import CarniVision

/// Stub backend so AuthService transitions can be tested without network.
final class StubAuthBackend: AuthBackend {
    var signInResult: Result<AuthIdentity, Error> = .failure(NSError(domain: "stub", code: 0))
    var signUpResult: Result<AuthIdentity, Error> = .failure(NSError(domain: "stub", code: 0))
    var signOutError: Error?

    func signIn(email: String, password: String) async throws -> AuthIdentity {
        try signInResult.get()
    }
    func signUp(email: String, password: String) async throws -> AuthIdentity {
        try signUpResult.get()
    }
    func signOut() async throws {
        if let signOutError { throw signOutError }
    }
    func restoreSession() async -> AuthIdentity? { nil }
}

@MainActor
final class AuthServiceTests: XCTestCase {
    func testSignInPublishesIdentityAndClearsError() async {
        let backend = StubAuthBackend()
        let auth = AuthService(backend: backend)

        // Phase 1: fail — errorMessage should be populated.
        backend.signInResult = .failure(NSError(domain: "auth", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Bad credentials"]))
        await auth.signIn(email: "a@b.com", password: "wrong")
        XCTAssertNil(auth.identity, "identity must stay nil after failure")
        XCTAssertNotNil(auth.errorMessage, "errorMessage must be set after failure")

        // Phase 2: succeed — identity published AND errorMessage cleared.
        backend.signInResult = .success(AuthIdentity(userID: "uid-123", accessToken: "jwt-abc"))
        await auth.signIn(email: "a@b.com", password: "pw")
        XCTAssertEqual(auth.identity?.userID, "uid-123")
        XCTAssertEqual(auth.accessToken, "jwt-abc")
        XCTAssertNil(auth.errorMessage, "errorMessage must be cleared after successful sign-in")
        XCTAssertFalse(auth.isWorking)
    }

    func testSignInFailureSetsErrorMessageAndLeavesIdentityNil() async {
        let backend = StubAuthBackend()
        backend.signInResult = .failure(NSError(domain: "auth", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Invalid login credentials"]))
        let auth = AuthService(backend: backend)

        await auth.signIn(email: "a@b.com", password: "wrong")

        XCTAssertNil(auth.identity)
        XCTAssertNil(auth.accessToken)
        XCTAssertEqual(auth.errorMessage, "Invalid login credentials")
        XCTAssertFalse(auth.isWorking)
    }

    func testSignOutClearsIdentity() async {
        let backend = StubAuthBackend()
        backend.signInResult = .success(AuthIdentity(userID: "uid-123", accessToken: "jwt-abc"))
        let auth = AuthService(backend: backend)
        await auth.signIn(email: "a@b.com", password: "pw")

        await auth.signOut()

        XCTAssertNil(auth.identity)
        XCTAssertNil(auth.accessToken)
    }
}
