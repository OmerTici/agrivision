import XCTest
@testable import AgriVision

/// Stub backend so AuthService transitions can be tested without network.
final class StubAuthBackend: AuthBackend {
    var signInResult: Result<AuthIdentity, Error> = .failure(NSError(domain: "stub", code: 0))
    var signUpResult: Result<SignUpOutcome, Error> = .failure(NSError(domain: "stub", code: 0))
    var signOutError: Error?
    var updateEmailError: Error?
    var reauthenticateError: Error?
    var updatePasswordError: Error?
    /// Records the last nonce passed to updatePassword so tests can assert it.
    private(set) var lastUpdatePasswordNonce: String?
    private(set) var reauthenticateCallCount = 0

    func signIn(email: String, password: String) async throws -> AuthIdentity {
        try signInResult.get()
    }
    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        try signUpResult.get()
    }
    func signOut() async throws {
        if let signOutError { throw signOutError }
    }
    func updateEmail(_ email: String) async throws {
        if let updateEmailError { throw updateEmailError }
    }
    func sendReauthenticationCode() async throws {
        reauthenticateCallCount += 1
        if let reauthenticateError { throw reauthenticateError }
    }
    func updatePassword(_ password: String, nonce: String) async throws {
        lastUpdatePasswordNonce = nonce
        if let updatePasswordError { throw updatePasswordError }
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

    func testSendPasswordChangeCodeReportsSuccessAndFailure() async {
        let backend = StubAuthBackend()
        let auth = AuthService(backend: backend)

        // Success: reauthenticate is invoked and no error surfaces.
        let sent = await auth.sendPasswordChangeCode()
        XCTAssertTrue(sent)
        XCTAssertEqual(backend.reauthenticateCallCount, 1)
        XCTAssertNil(auth.errorMessage)

        // Failure: error is surfaced and the call reports false.
        backend.reauthenticateError = NSError(domain: "auth", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "Too many requests"])
        let failed = await auth.sendPasswordChangeCode()
        XCTAssertFalse(failed)
        XCTAssertEqual(auth.errorMessage, "Too many requests")
    }

    func testUpdatePasswordPassesNonceAndReportsSuccess() async {
        let backend = StubAuthBackend()
        let auth = AuthService(backend: backend)

        let ok = await auth.updatePassword(new: "newSecret1", code: "123456")
        XCTAssertTrue(ok)
        XCTAssertEqual(backend.lastUpdatePasswordNonce, "123456")
        XCTAssertNil(auth.errorMessage)
        XCTAssertFalse(auth.isWorking)
    }

    func testUpdatePasswordFailureSurfacesError() async {
        let backend = StubAuthBackend()
        backend.updatePasswordError = NSError(domain: "auth", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Invalid nonce"])
        let auth = AuthService(backend: backend)

        let ok = await auth.updatePassword(new: "newSecret1", code: "000000")
        XCTAssertFalse(ok)
        XCTAssertEqual(auth.errorMessage, "Invalid nonce")
        XCTAssertFalse(auth.isWorking)
    }
}
