# CarniVision iOS Recognition Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing CarniVision SwiftUI app to the live Cloud Run embedder so a farmer can enroll a cow's muzzle (5-photo guided burst + 1 full-body shot) and identify animals in real time, replacing the fake auth flag with real Supabase sessions.

**Architecture:** A thin client layer sits beside the unchanged camera pipeline: `SupabaseClientProvider` vends a configured SDK client; `AuthService` (ObservableObject) owns the session and gates `RootView`; `AnimalRepository` inserts animal rows; `RecognitionService` (protocol + `CloudRunRecognitionService`) talks multipart/form-data to the embedder over `URLSession` with a Bearer JWT. The existing `CameraModel` gains an opt-in enrollment session (collect 5 crops + 1 full frame) and an identify call; everything is injected so SwiftUI previews and unit tests use mocks.

**Tech Stack:** Swift 5.9+/SwiftUI (iOS 17), supabase-swift (SPM, pinned), URLSession multipart, XCTest with MockURLProtocol.

---

## Ground-truth facts (verified against the repo, do not re-derive)

- Xcode project: `CarniVision.xcodeproj`, `objectVersion = 56`, single app target/scheme **`CarniVision`**, bundle `com.carnivision.app`, team `Z23895JP8U`, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `SWIFT_VERSION = 5.0`. There is currently **no test target** and **no SPM package** (`XCRemoteSwiftPackageReference` count = 0).
- App entry: `CarniVision/CarniVisionApp.swift` → `RootView()`.
- `RootView` gates on a fake `@State private var isAuthenticated = false` and shows `LandingView { … isAuthenticated = true }`.
- `LandingView` hosts `SignInForm` and `SignUpForm`, each taking `onBack`, `onSwitch…`, and `onAuthenticated` closures. `SignInForm.handleLogin()` and `SignUpForm.handleSignUp()` are `print` stubs that immediately call `onAuthenticated()`.
- `MainTabView` owns `@StateObject private var store = HerdStore()` and renders `AddAnimalScreen()` for `.addAnimal` and `CameraScreen(onClose:)` for `.camera`.
- `CameraModel` (in `CarniVision/Views/Main/CameraView.swift`) publishes `lastPhoto`, `croppedMuzzle`, `captureSucceeded`, `captureFailed`, `failureMessage`, `isProcessing`, `countdown`, `faceVisible`, `canManualCapture`, `debugReadout`. Capture flow: `capturePhoto()` → `PhotoCaptureDelegate` → `processCapturedPhoto` → `finishSuccess(crop:readout:)` / `finishFailure(_:)`. Auto-capture is gated by `processAutomaticFrame`; `hasAutoCaptured` blocks further frames.
- `UIImage.normalizedCGImage()` already exists (in `MuzzleDetectorService.swift`).
- Localization: `LanguageManager.shared.t(_:)` with two in-code dictionaries (`.english`, `.turkish`) in `CarniVision/Models/Localization.swift`. Add keys to **both** dictionaries.
- `AddAnimalScreen` form fields: `name`, `tag`, `breed` (String from `breeds`), `sex: AnimalSex` (`.female`/`.male`), `birthDate: Date`, `weightText`. It calls `store.addAnimal(…)` then shows a toast.
- `HerdStore.addAnimal(name:tag:breed:sex:birthDate:initialWeightKg:muzzleRegistered:)` inserts an in-memory `Animal`.
- **Server contract (from `server/app/main.py` + `server/app/schemas.py`):**
  - `GET /health` → `{ "status": "ok"|"loading", "model_loaded": Bool }`. No auth required.
  - `POST /identify` — multipart field **`image`** (single file). Auth via `Authorization: Bearer <jwt>` (`current_uid` dependency). Returns `IdentifyResponse { decision: String, animal_id: String?, name: String?, score: Double, margin: Double, candidates: [{animal_id, name?, sim}] }`.
  - `POST /enroll` — multipart fields **`animal_id`** (form text), **`images`** (repeated file part, one per muzzle crop), **`full_images`** (repeated file part, default empty). Auth Bearer. Returns `EnrollResponse { enrolled_count: Int, full_images_stored: Int }`.
- **Embedder base URL:** `https://carnivision-embedder-78377568014.europe-west1.run.app`
- **Supabase URL:** `https://xznmsmweefckkqjfepqs.supabase.co` (project ref `xznmsmweefckkqjfepqs`).

> **Environment note for the executor:** `xcodebuild` requires a full Xcode install (`xcode-select -s /Applications/Xcode.app`). If only Command Line Tools are active, the test/`xcodebuild` steps must run on a machine with Xcode. Before running any test command, confirm the simulator name with `xcrun simctl list devices available | grep iPhone | head` and substitute an available device into the `-destination`.

---

## File Structure

**Create:**
- `CarniVision/Config/AppConfig.swift` — reads `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `EMBEDDER_URL` from Info.plist; one typed accessor.
- `CarniVision/Services/SupabaseClientProvider.swift` — singleton vending the configured `SupabaseClient`.
- `CarniVision/Services/AuthService.swift` — ObservableObject wrapping Supabase Auth (`signIn`/`signUp`/`signOut`/`session`/`accessToken`/`errorMessage`).
- `CarniVision/Services/AnimalRepository.swift` — inserts a row into the `animals` table; returns the new UUID string.
- `CarniVision/Services/RecognitionModels.swift` — `IdentifyResult`, `EnrollResult`, `Candidate`, `RecognitionError`.
- `CarniVision/Services/MultipartFormData.swift` — pure multipart/form-data encoder (TDD'd).
- `CarniVision/Services/RecognitionService.swift` — `RecognitionService` protocol + `MockRecognitionService`.
- `CarniVision/Services/CloudRunRecognitionService.swift` — URLSession implementation (`warmUp`/`identify`/`enroll`, Bearer token, JPEG 0.85, full-frame downscale ≤ 2048 px).
- `CarniVision/Services/ImageEncoding.swift` — `UIImage` JPEG-encode + downscale helpers shared by the service.
- `CarniVisionTests/MultipartFormDataTests.swift` — unit tests for the encoder.
- `CarniVisionTests/RecognitionDecodingTests.swift` — JSON→`IdentifyResult`/`EnrollResult` decoding + MockURLProtocol round-trip (field names, Bearer header).
- `CarniVisionTests/AuthServiceTests.swift` — session/errorMessage transitions through a stubbed auth client.
- `README.md` (append section) — operator setup: filling `SUPABASE_ANON_KEY`.

**Modify:**
- `CarniVision/Info.plist` — add `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `EMBEDDER_URL` keys (anon key placeholder).
- `CarniVision/CarniVisionApp.swift` — construct shared `AuthService` + `RecognitionService`, inject as environment objects, fire `warmUp()` on launch.
- `CarniVision/Views/RootView.swift` — gate on `auth.session != nil` instead of the fake flag.
- `CarniVision/Views/LoginView.swift` — real `signIn`, inline error, loading state.
- `CarniVision/Views/SignUpView.swift` — real `signUp`, inline error, loading state.
- `CarniVision/Views/Main/AddAnimalView.swift` — on Save: create row in Supabase, then present `CameraScreen` in enrollment mode with the new `animalID`.
- `CarniVision/Views/Main/CameraView.swift` — `CameraModel` gains enrollment session state + `identify`/`enroll` calls; `CameraScreen` gains enrollment progress ring, full-body prompt, identify result card.
- `CarniVision/Models/Localization.swift` — add EN/TR strings for new UI.
- `CarniVision.xcodeproj/project.pbxproj` — register new source files, the supabase-swift package, and the new test target (via Xcode GUI per Task 1/Task 2 instructions).

---

## Task 1: Add supabase-swift SPM package + a unit-test target

These are Xcode-GUI operations (the executor must perform them in Xcode; they cannot be done reliably by hand-editing `project.pbxproj`). Each ends with a verification command.

**Files:**
- Modify: `CarniVision.xcodeproj/project.pbxproj` (written by Xcode)

- [ ] **Step 1: Open the project**

```bash
xed CarniVision.xcodeproj
```

- [ ] **Step 2: Add the supabase-swift package, pinned**

In Xcode: **File ▸ Add Package Dependencies…** → enter `https://github.com/supabase/supabase-swift` → Dependency Rule: **Exact Version** `2.5.1` (pin; do not use "Up to Next Major"). Add. When prompted for products, check **only `Supabase`** and add it to the **CarniVision** app target.

> If `2.5.1` is unavailable in your SPM cache, pick the newest available 2.x exact version and record it in the README setup note. The API used in this plan (`SupabaseClient(supabaseURL:supabaseKey:)`, `client.auth.signIn(email:password:)`, `client.auth.signUp(email:password:)`, `client.auth.signOut()`, `client.auth.session`, `auth.authStateChanges`, `client.from("animals").insert(...).select().single().execute()`) is stable across supabase-swift 2.x.

- [ ] **Step 3: Add a unit-test target**

In Xcode: **File ▸ New ▸ Target… ▸ Unit Testing Bundle**. Product Name: **`CarniVisionTests`**. Team: `Z23895JP8U`. Target to be Tested: **CarniVision**. Finish. This creates the `CarniVisionTests` group/target and a default test file — delete the auto-generated `CarniVisionTests.swift` placeholder (we add our own test files in later tasks).

- [ ] **Step 4: Verify the package and test target are registered**

```bash
grep -c "XCRemoteSwiftPackageReference" CarniVision.xcodeproj/project.pbxproj
grep -nE "supabase-swift|productType = \"com.apple.product-type.bundle.unit-test\"|name = CarniVisionTests" CarniVision.xcodeproj/project.pbxproj | head
```
Expected: the `XCRemoteSwiftPackageReference` count is `>= 1`; the second grep shows the supabase-swift repo URL and a `CarniVisionTests` unit-test target.

- [ ] **Step 5: Confirm the schemes Xcode sees**

```bash
xcodebuild -list -project CarniVision.xcodeproj 2>&1 | sed -n '1,40p'
```
Expected: under **Schemes**, `CarniVision` appears. (If `xcodebuild` errors with "requires Xcode", run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` first.)

- [ ] **Step 6: Commit**

```bash
git add CarniVision.xcodeproj
git commit -m "Add supabase-swift package and CarniVisionTests target"
```

---

## Task 2: Config keys (Info.plist) + AppConfig + README note

**Files:**
- Modify: `CarniVision/Info.plist`
- Create: `CarniVision/Config/AppConfig.swift`
- Modify: `README.md` (append)

- [x] **Step 1: Add config keys to Info.plist**

Replace this exact block in `CarniVision/Info.plist`:

```xml
	<key>NSCameraUsageDescription</key>
	<string>Carni_vision uses the camera to scan and identify animals.</string>
```

with:

```xml
	<key>NSCameraUsageDescription</key>
	<string>Carni_vision uses the camera to scan and identify animals.</string>
	<key>SUPABASE_URL</key>
	<string>https://xznmsmweefckkqjfepqs.supabase.co</string>
	<key>SUPABASE_ANON_KEY</key>
	<string>REPLACE_WITH_SUPABASE_ANON_KEY</string>
	<key>EMBEDDER_URL</key>
	<string>https://carnivision-embedder-78377568014.europe-west1.run.app</string>
```

- [x] **Step 2: Create AppConfig**

Create `CarniVision/Config/AppConfig.swift`:

```swift
import Foundation

/// Reads runtime configuration from Info.plist. The operator fills
/// `SUPABASE_ANON_KEY` before building (see README ▸ Setup).
enum AppConfig {
    private static func string(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            fatalError("Missing Info.plist key: \(key)")
        }
        return value
    }

    static var supabaseURL: URL {
        guard let url = URL(string: string("SUPABASE_URL")) else {
            fatalError("SUPABASE_URL is not a valid URL")
        }
        return url
    }

    static var supabaseAnonKey: String {
        let key = string("SUPABASE_ANON_KEY")
        if key == "REPLACE_WITH_SUPABASE_ANON_KEY" {
            fatalError("SUPABASE_ANON_KEY placeholder not replaced — see README ▸ Setup")
        }
        return key
    }

    static var embedderBaseURL: URL {
        guard let url = URL(string: string("EMBEDDER_URL")) else {
            fatalError("EMBEDDER_URL is not a valid URL")
        }
        return url
    }
}
```

- [x] **Step 3: Register AppConfig.swift in the app target**

In Xcode, drag `CarniVision/Config/AppConfig.swift` into the **CarniVision** group so it joins the app target's Compile Sources (or it is auto-added if created via Xcode's New File). Verify:

```bash
grep -c "AppConfig.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: `>= 1`.

- [x] **Step 4: Append operator setup to README**

Append to `README.md`:

```markdown
## Setup (operator inputs required before building)

1. **Supabase anon key.** In the Supabase dashboard → Project Settings → API, copy the
   **anon / publishable** key (NOT the service-role key). Open
   `CarniVision/Info.plist` and replace `REPLACE_WITH_SUPABASE_ANON_KEY` in the
   `SUPABASE_ANON_KEY` value with the copied key. The service-role key must never ship
   in the app.
2. **SPM package.** supabase-swift is pinned to an exact version in the Xcode project.
   If your machine resolved a different 2.x version, note it here.
3. **Sign Up button.** Supabase project signups are currently open. If you want to hide
   in-app sign up, see `AuthService` / `SignUpForm`.
```

- [x] **Step 5: Commit**

```bash
git add CarniVision/Info.plist CarniVision/Config/AppConfig.swift README.md CarniVision.xcodeproj
git commit -m "Add app config keys and AppConfig accessor"
```

---

## Task 3: SupabaseClientProvider

**Files:**
- Create: `CarniVision/Services/SupabaseClientProvider.swift`

- [x] **Step 1: Create the provider**

Create `CarniVision/Services/SupabaseClientProvider.swift`:

```swift
import Foundation
import Supabase

/// Vends the single configured Supabase client for the whole app.
/// The SDK persists the auth session to the keychain across launches.
enum SupabaseClientProvider {
    static let shared: SupabaseClient = SupabaseClient(
        supabaseURL: AppConfig.supabaseURL,
        supabaseKey: AppConfig.supabaseAnonKey
    )
}
```

- [x] **Step 2: Register the file in the app target**

In Xcode, add `CarniVision/Services/SupabaseClientProvider.swift` to the **CarniVision** target. Verify:

```bash
grep -c "SupabaseClientProvider.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: `>= 1`.

- [x] **Step 3: Commit**

```bash
git add CarniVision/Services/SupabaseClientProvider.swift CarniVision.xcodeproj
git commit -m "Add SupabaseClientProvider"
```

---

## Task 4: AuthService (with TDD for session/error transitions)

We test the observable transitions behind a small protocol so tests do not hit the network. The production `AuthService` wraps the real client; `AuthServiceTests` injects a stub.

**Files:**
- Create: `CarniVision/Services/AuthService.swift`
- Test: `CarniVisionTests/AuthServiceTests.swift`

- [x] **Step 1: Write the failing test**

Create `CarniVisionTests/AuthServiceTests.swift`:

```swift
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
        backend.signInResult = .success(AuthIdentity(userID: "uid-123", accessToken: "jwt-abc"))
        let auth = AuthService(backend: backend)

        await auth.signIn(email: "a@b.com", password: "pw")

        XCTAssertEqual(auth.identity?.userID, "uid-123")
        XCTAssertEqual(auth.accessToken, "jwt-abc")
        XCTAssertNil(auth.errorMessage)
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
```

- [x] **Step 2: Run the test, verify it fails to build**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: FAIL — `AuthBackend`, `AuthIdentity`, `AuthService` are undefined.

- [x] **Step 3: Write the implementation**

Create `CarniVision/Services/AuthService.swift`:

```swift
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
```

- [x] **Step 4: Register both files in their targets**

In Xcode add `CarniVision/Services/AuthService.swift` to the **CarniVision** target and `CarniVisionTests/AuthServiceTests.swift` to the **CarniVisionTests** target. Verify:

```bash
grep -c "AuthService.swift" CarniVision.xcodeproj/project.pbxproj
grep -c "AuthServiceTests.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: each `>= 1`.

- [x] **Step 5: Run the test, verify it passes**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CarniVisionTests/AuthServiceTests 2>&1 | tail -20
```
Expected: PASS (3 tests).

- [x] **Step 6: Commit**

```bash
git add CarniVision/Services/AuthService.swift CarniVisionTests/AuthServiceTests.swift CarniVision.xcodeproj
git commit -m "Add AuthService with stubbed-backend tests"
```

---

## Task 5: Add auth localization strings

**Files:**
- Modify: `CarniVision/Models/Localization.swift`

- [ ] **Step 1: Add EN keys**

In `CarniVision/Models/Localization.swift`, in the `.english` dictionary, replace this exact line:

```swift
            "auth.backToLogin": "Back to login",
```

with:

```swift
            "auth.backToLogin": "Back to login",
            "auth.error.generic": "Something went wrong. Please try again.",
            "auth.signingIn": "Signing in…",
            "auth.signingUp": "Creating account…",
            "auth.mismatch": "Passwords do not match.",
```

- [ ] **Step 2: Add TR keys**

In the `.turkish` dictionary, replace this exact line:

```swift
            "auth.backToLogin": "Girişe dön",
```

with:

```swift
            "auth.backToLogin": "Girişe dön",
            "auth.error.generic": "Bir şeyler ters gitti. Lütfen tekrar deneyin.",
            "auth.signingIn": "Giriş yapılıyor…",
            "auth.signingUp": "Hesap oluşturuluyor…",
            "auth.mismatch": "Şifreler eşleşmiyor.",
```

- [ ] **Step 3: Commit**

```bash
git add CarniVision/Models/Localization.swift
git commit -m "Add auth flow localization strings"
```

---

## Task 6: Wire RootView, App entry, LoginView, SignUpView to AuthService

**Files:**
- Modify: `CarniVision/CarniVisionApp.swift`
- Modify: `CarniVision/Views/RootView.swift`
- Modify: `CarniVision/Views/LoginView.swift`
- Modify: `CarniVision/Views/SignUpView.swift`

- [ ] **Step 1: Inject AuthService at the app root**

Replace the entire contents of `CarniVision/CarniVisionApp.swift`:

```swift
import SwiftUI

@main
struct CarniVisionApp: App {
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .task { await auth.bootstrap() }
        }
    }
}
```

> The shared `RecognitionService` is injected lower down (Task 11) so the camera view can receive it; the app-level `warmUp()` call is also added in Task 11 once the service type exists.

- [ ] **Step 2: Gate RootView on the session**

Replace the entire contents of `CarniVision/Views/RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        ZStack {
            if auth.identity != nil {
                MainTabView()
                    .transition(.opacity)
            } else {
                LandingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: auth.identity)
    }
}
```

- [ ] **Step 3: Drop the obsolete onAuthenticated closure from LandingView**

In `CarniVision/Views/LandingView.swift`, replace this exact block:

```swift
    var onAuthenticated: () -> Void = {}

    @ObservedObject private var lang = LanguageManager.shared
    @State private var screen: Screen = .landing
```

with:

```swift
    @ObservedObject private var lang = LanguageManager.shared
    @State private var screen: Screen = .landing
```

Then replace this exact block (the SignIn branch):

```swift
            if screen == .signIn {
                SignInForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignUp: { goTo(.signUp) },
                    onAuthenticated: onAuthenticated
                )
                .transition(.move(edge: .bottom))
            }

            if screen == .signUp {
                SignUpForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignIn: { goTo(.signIn) },
                    onAuthenticated: onAuthenticated
                )
                .transition(.move(edge: .bottom))
            }
```

with:

```swift
            if screen == .signIn {
                SignInForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignUp: { goTo(.signUp) }
                )
                .transition(.move(edge: .bottom))
            }

            if screen == .signUp {
                SignUpForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignIn: { goTo(.signIn) }
                )
                .transition(.move(edge: .bottom))
            }
```

- [ ] **Step 4: Real sign-in in LoginView**

In `CarniVision/Views/LoginView.swift`, replace this exact block:

```swift
struct SignInForm: View {
    var onBack: () -> Void
    var onSwitchToSignUp: () -> Void
    var onAuthenticated: () -> Void = {}

    @ObservedObject private var lang = LanguageManager.shared
    @State private var loginMethod: AuthMethod = .email
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var showForgotPassword = false
```

with:

```swift
struct SignInForm: View {
    var onBack: () -> Void
    var onSwitchToSignUp: () -> Void

    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @State private var loginMethod: AuthMethod = .email
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var showForgotPassword = false
```

Then replace this exact block (the login button + footer):

```swift
                    PrimaryAuthButton(title: lang.t("auth.login")) {
                        handleLogin()
                    }
                }
```

with:

```swift
                    if let error = auth.errorMessage {
                        Text(error)
                            .font(CarniFont.regular(13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PrimaryAuthButton(
                        title: auth.isWorking ? lang.t("auth.signingIn") : lang.t("auth.login")
                    ) {
                        handleLogin()
                    }
                    .disabled(auth.isWorking || email.isEmpty || password.isEmpty)
                }
```

Then replace this exact block (the stub handler):

```swift
    private func handleLogin() {
        switch loginMethod {
        case .email:
            print("Login with email: \(email)")
        case .phone:
            print("Login with phone: \(selectedCountry.dialCode) \(phoneNumber)")
        }
        onAuthenticated()
    }
}
```

with:

```swift
    private func handleLogin() {
        Task {
            await auth.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
        }
    }
}
```

> Phone login is not wired in this sub-project (the embedder uses email/JWT auth). The phone picker stays in the UI but `handleLogin()` always uses the email field; leave a follow-up note. Successful sign-in flips `auth.identity`, which `RootView` observes — no closure callback needed.

- [ ] **Step 5: Real sign-up in SignUpView**

In `CarniVision/Views/SignUpView.swift`, replace this exact block:

```swift
struct SignUpForm: View {
    var onBack: () -> Void
    var onSwitchToSignIn: () -> Void
    var onAuthenticated: () -> Void = {}

    @ObservedObject private var lang = LanguageManager.shared
    @State private var fullName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var confirmPassword = ""
```

with:

```swift
struct SignUpForm: View {
    var onBack: () -> Void
    var onSwitchToSignIn: () -> Void

    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @State private var fullName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var confirmPassword = ""
```

Then replace this exact block (submit button):

```swift
                PrimaryAuthButton(title: lang.t("auth.signupAction"), compact: true, disabled: !canSubmit) {
                    handleSignUp()
                }
            }
```

with:

```swift
                if let error = auth.errorMessage {
                    Text(error)
                        .font(CarniFont.regular(13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrimaryAuthButton(
                    title: auth.isWorking ? lang.t("auth.signingUp") : lang.t("auth.signupAction"),
                    compact: true,
                    disabled: !canSubmit || auth.isWorking
                ) {
                    handleSignUp()
                }
            }
```

Then replace this exact block (stub handler):

```swift
    private func handleSignUp() {
        print("Sign up — name: \(fullName), email: \(email), phone: \(selectedCountry.dialCode) \(phoneNumber)")
        onAuthenticated()
    }
}
```

with:

```swift
    private func handleSignUp() {
        guard password == confirmPassword else {
            auth.errorMessage = lang.t("auth.mismatch")
            return
        }
        Task {
            await auth.signUp(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
        }
    }
}
```

- [ ] **Step 6: Build to confirm wiring compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add CarniVision/CarniVisionApp.swift CarniVision/Views/RootView.swift CarniVision/Views/LandingView.swift CarniVision/Views/LoginView.swift CarniVision/Views/SignUpView.swift
git commit -m "Replace fake auth flag with AuthService session gating"
```

---

## Task 7: Recognition models

**Files:**
- Create: `CarniVision/Services/RecognitionModels.swift`

- [ ] **Step 1: Create the models**

Create `CarniVision/Services/RecognitionModels.swift`. Field names use `CodingKeys` to map the server's snake_case JSON.

```swift
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
```

- [ ] **Step 2: Register in the app target**

In Xcode add `CarniVision/Services/RecognitionModels.swift` to the **CarniVision** target. Verify:

```bash
grep -c "RecognitionModels.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: `>= 1`.

- [ ] **Step 3: Commit**

```bash
git add CarniVision/Services/RecognitionModels.swift CarniVision.xcodeproj
git commit -m "Add recognition response models"
```

---

## Task 8: MultipartFormData encoder (TDD)

**Files:**
- Create: `CarniVision/Services/MultipartFormData.swift`
- Test: `CarniVisionTests/MultipartFormDataTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CarniVisionTests/MultipartFormDataTests.swift`:

```swift
import XCTest
@testable import CarniVision

final class MultipartFormDataTests: XCTestCase {
    func testContentTypeHeaderCarriesBoundary() {
        let form = MultipartFormData(boundary: "BOUND123")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUND123")
    }

    func testTextFieldEncoding() {
        var form = MultipartFormData(boundary: "BOUND123")
        form.appendField(name: "animal_id", value: "abc-123")
        let body = String(data: form.finalizedBody(), encoding: .utf8)!

        XCTAssertTrue(body.contains("--BOUND123\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"animal_id\"\r\n\r\nabc-123\r\n"))
        XCTAssertTrue(body.hasSuffix("--BOUND123--\r\n"))
    }

    func testFilePartEncodingIncludesFilenameAndContentType() {
        var form = MultipartFormData(boundary: "BOUND123")
        let bytes = Data([0xFF, 0xD8, 0xFF])
        form.appendFile(name: "image", filename: "muzzle.jpg", mimeType: "image/jpeg", data: bytes)
        let body = form.finalizedBody()
        let text = String(data: body, encoding: .isoLatin1)!

        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"image\"; filename=\"muzzle.jpg\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg\r\n\r\n"))
        // raw JPEG magic bytes survive
        XCTAssertTrue(body.range(of: Data([0xFF, 0xD8, 0xFF])) != nil)
    }

    func testRepeatedFilePartsShareFieldName() {
        var form = MultipartFormData(boundary: "B")
        form.appendFile(name: "images", filename: "a.jpg", mimeType: "image/jpeg", data: Data([0x01]))
        form.appendFile(name: "images", filename: "b.jpg", mimeType: "image/jpeg", data: Data([0x02]))
        let text = String(data: form.finalizedBody(), encoding: .isoLatin1)!
        let occurrences = text.components(separatedBy: "name=\"images\"").count - 1
        XCTAssertEqual(occurrences, 2)
    }

    func testRandomBoundaryInitProducesNonEmptyBoundary() {
        let form = MultipartFormData()
        XCTAssertFalse(form.boundary.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to build**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CarniVisionTests/MultipartFormDataTests 2>&1 | tail -20
```
Expected: FAIL — `MultipartFormData` undefined.

- [ ] **Step 3: Write the implementation**

Create `CarniVision/Services/MultipartFormData.swift`:

```swift
import Foundation

/// Builds a `multipart/form-data` request body. Field order is preserved.
struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Returns the body with the closing boundary appended. Non-mutating so the
    /// builder can be reused/inspected in tests.
    func finalizedBody() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    private mutating func append(_ string: String) {
        body.append(string.data(using: .utf8)!)
    }
}
```

- [ ] **Step 4: Register both files in their targets**

In Xcode add `CarniVision/Services/MultipartFormData.swift` to the **CarniVision** target and `CarniVisionTests/MultipartFormDataTests.swift` to the **CarniVisionTests** target. Verify:

```bash
grep -c "MultipartFormData.swift" CarniVision.xcodeproj/project.pbxproj
grep -c "MultipartFormDataTests.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: each `>= 1`.

- [ ] **Step 5: Run the test, verify it passes**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CarniVisionTests/MultipartFormDataTests 2>&1 | tail -20
```
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add CarniVision/Services/MultipartFormData.swift CarniVisionTests/MultipartFormDataTests.swift CarniVision.xcodeproj
git commit -m "Add multipart/form-data encoder with tests"
```

---

## Task 9: Image encoding helpers + RecognitionService protocol + Mock

**Files:**
- Create: `CarniVision/Services/ImageEncoding.swift`
- Create: `CarniVision/Services/RecognitionService.swift`

- [ ] **Step 1: Create the image helpers**

Create `CarniVision/Services/ImageEncoding.swift`:

```swift
import UIKit

enum ImageEncoding {
    /// JPEG-encodes a muzzle crop at quality 0.85 (native size; crops are small).
    static func muzzleJPEG(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.85)
    }

    /// Downscales to <= maxDimension on the longest side, then JPEG-encodes at 0.85.
    static func fullBodyJPEG(_ image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        downscaled(image, maxDimension: maxDimension).jpegData(compressionQuality: 0.85)
    }

    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
```

- [ ] **Step 2: Create the protocol + mock**

Create `CarniVision/Services/RecognitionService.swift`:

```swift
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
```

> `IdentifyResult`/`EnrollResult` are `Decodable`-only structs (Task 7). Their memberwise initializers are still synthesized because no custom `init` is declared, so the mock can construct them directly.

- [ ] **Step 3: Register both files in the app target**

In Xcode add both files to the **CarniVision** target. Verify:

```bash
grep -c "ImageEncoding.swift" CarniVision.xcodeproj/project.pbxproj
grep -c "RecognitionService.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: each `>= 1`.

- [ ] **Step 4: Commit**

```bash
git add CarniVision/Services/ImageEncoding.swift CarniVision/Services/RecognitionService.swift CarniVision.xcodeproj
git commit -m "Add image encoding helpers and RecognitionService protocol with mock"
```

---

## Task 10: CloudRunRecognitionService (with MockURLProtocol tests)

**Files:**
- Create: `CarniVision/Services/CloudRunRecognitionService.swift`
- Test: `CarniVisionTests/RecognitionDecodingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CarniVisionTests/RecognitionDecodingTests.swift`:

```swift
import XCTest
@testable import CarniVision

/// Intercepts URLSession requests so we can assert on them and return fixtures.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody for stream bodies; capture via bodyStream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            MockURLProtocol.lastRequestBody = data
        } else {
            MockURLProtocol.lastRequestBody = request.httpBody
        }

        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "no-handler", code: 0))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class RecognitionDecodingTests: XCTestCase {
    private func makeService(token: String? = "jwt-token") -> CloudRunRecognitionService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CloudRunRecognitionService(
            baseURL: URL(string: "https://embedder.example.com")!,
            session: session,
            tokenProvider: { token }
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    func testIdentifyDecodesResponseAndSendsBearerAndImageField() async throws {
        let json = """
        {"decision":"identified","animal_id":"a1","name":"Daisy",
         "score":0.91,"margin":0.2,
         "candidates":[{"animal_id":"a1","name":"Daisy","sim":0.91}]}
        """.data(using: .utf8)!
        var capturedAuth: String?
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            capturedURL = request.url
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }

        let service = makeService()
        let result = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))

        XCTAssertEqual(result.decision, "identified")
        XCTAssertEqual(result.animalId, "a1")
        XCTAssertEqual(result.name, "Daisy")
        XCTAssertEqual(result.score, 0.91, accuracy: 0.0001)
        XCTAssertEqual(result.candidates.first?.sim, 0.91, accuracy: 0.0001)
        XCTAssertEqual(capturedAuth, "Bearer jwt-token")
        XCTAssertEqual(capturedURL?.absoluteString, "https://embedder.example.com/identify")

        let body = String(data: MockURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(body.contains("name=\"image\"; filename="))
    }

    func testEnrollDecodesResponseAndSendsAllFields() async throws {
        let json = """
        {"enrolled_count":5,"full_images_stored":1}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }

        let service = makeService()
        let muzzles = (0..<5).map { _ in Data([0xFF, 0xD8, 0xFF]) }
        let result = try await service.enroll(animalID: "abc-123",
                                              muzzleJpegs: muzzles,
                                              fullJpeg: Data([0xFF, 0xD8, 0xFF]))

        XCTAssertEqual(result.enrolledCount, 5)
        XCTAssertEqual(result.fullImagesStored, 1)

        let body = String(data: MockURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(body.contains("name=\"animal_id\"\r\n\r\nabc-123"))
        XCTAssertEqual(body.components(separatedBy: "name=\"images\"").count - 1, 5)
        XCTAssertEqual(body.components(separatedBy: "name=\"full_images\"").count - 1, 1)
    }

    func testHTTPErrorThrowsHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 502,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, Data("bad gateway".utf8))
        }
        let service = makeService()
        do {
            _ = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))
            XCTFail("expected throw")
        } catch let RecognitionError.http(status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("expected RecognitionError.http, got \(error)")
        }
    }

    func testMissingTokenThrowsNotAuthenticated() async {
        let service = makeService(token: nil)
        do {
            _ = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))
            XCTFail("expected throw")
        } catch RecognitionError.notAuthenticated {
            // ok
        } catch {
            XCTFail("expected notAuthenticated, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to build**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CarniVisionTests/RecognitionDecodingTests 2>&1 | tail -20
```
Expected: FAIL — `CloudRunRecognitionService` undefined.

- [ ] **Step 3: Write the implementation**

Create `CarniVision/Services/CloudRunRecognitionService.swift`:

```swift
import Foundation

/// Talks to the Cloud Run embedder over multipart/form-data with a Bearer JWT.
@MainActor
final class CloudRunRecognitionService: ObservableObject, RecognitionService {
    /// True once /health reports the model is loaded; drives "waking up" UI.
    @Published var isReady = false

    private let baseURL: URL
    private let session: URLSession
    /// Returns the current access token (from AuthService) at call time.
    private let tokenProvider: () -> String?

    /// Cold-start budget for the first network call.
    private let coldStartTimeout: TimeInterval = 90

    init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func warmUp() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = coldStartTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            isReady = health.modelLoaded
        } catch {
            isReady = false
        }
    }

    func identify(jpegData: Data) async throws -> IdentifyResult {
        guard let token = tokenProvider() else { throw RecognitionError.notAuthenticated }
        var form = MultipartFormData()
        form.appendFile(name: "image", filename: "muzzle.jpg", mimeType: "image/jpeg", data: jpegData)
        let request = makeRequest(path: "identify", form: form, token: token)
        return try await send(request, decode: IdentifyResult.self)
    }

    func enroll(animalID: String, muzzleJpegs: [Data], fullJpeg: Data?) async throws -> EnrollResult {
        guard let token = tokenProvider() else { throw RecognitionError.notAuthenticated }
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
```

- [ ] **Step 4: Register both files in their targets**

In Xcode add `CarniVision/Services/CloudRunRecognitionService.swift` to **CarniVision** and `CarniVisionTests/RecognitionDecodingTests.swift` to **CarniVisionTests**. Verify:

```bash
grep -c "CloudRunRecognitionService.swift" CarniVision.xcodeproj/project.pbxproj
grep -c "RecognitionDecodingTests.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: each `>= 1`.

- [ ] **Step 5: Run the test, verify it passes**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CarniVisionTests/RecognitionDecodingTests 2>&1 | tail -20
```
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add CarniVision/Services/CloudRunRecognitionService.swift CarniVisionTests/RecognitionDecodingTests.swift CarniVision.xcodeproj
git commit -m "Add CloudRunRecognitionService with MockURLProtocol tests"
```

---

## Task 11: Inject RecognitionService + warmUp at app launch

**Files:**
- Modify: `CarniVision/CarniVisionApp.swift`

- [ ] **Step 1: Construct and inject the service, warm it up**

Replace the entire contents of `CarniVision/CarniVisionApp.swift` (it currently holds only `auth`):

```swift
import SwiftUI

@main
struct CarniVisionApp: App {
    @StateObject private var auth = AuthService()
    @StateObject private var recognition: CloudRunRecognitionService

    init() {
        // Build a recognition service whose token is read from the live session.
        let authService = AuthService()
        _auth = StateObject(wrappedValue: authService)
        _recognition = StateObject(wrappedValue: CloudRunRecognitionService(
            baseURL: AppConfig.embedderBaseURL,
            tokenProvider: { [weak authService] in authService?.accessToken }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(recognition)
                .task {
                    await auth.bootstrap()
                    await recognition.warmUp()
                }
        }
    }
}
```

> `CloudRunRecognitionService` is injected as a concrete `@StateObject` (not the `RecognitionService` protocol) so views can also observe its `@Published isReady`. Views that only need the protocol take it as a plain `RecognitionService` parameter (Task 13/14) sourced from this environment object.

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add CarniVision/CarniVisionApp.swift
git commit -m "Inject recognition service and warm it up at launch"
```

---

## Task 12: AnimalRepository

**Files:**
- Create: `CarniVision/Services/AnimalRepository.swift`

- [ ] **Step 1: Create the repository**

Create `CarniVision/Services/AnimalRepository.swift`. The insert sets `owner` explicitly (schema is `not null`, no default) and omits `status` (nullable). The SDK attaches the session JWT so RLS scopes the row.

```swift
import Foundation
import Supabase

/// One inserted animal's identifier (the new row's UUID, as a string).
struct CreatedAnimal {
    let id: String
}

/// Inserts animal rows into the embedder project's `animals` table.
struct AnimalRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    /// Row payload sent to Supabase. `birth_date` is an ISO-8601 date string
    /// (YYYY-MM-DD); `sex` is lowercased free text ("female" | "male").
    private struct AnimalInsert: Encodable {
        let owner: String
        let name: String
        let tag: String
        let breed: String
        let sex: String
        let birth_date: String
    }

    private struct AnimalRow: Decodable {
        let id: UUID
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Inserts a new animal owned by `ownerID` and returns its id.
    func create(
        ownerID: String,
        name: String,
        tag: String,
        breed: String,
        sex: AnimalSex,
        birthDate: Date
    ) async throws -> CreatedAnimal {
        let payload = AnimalInsert(
            owner: ownerID,
            name: name,
            tag: tag,
            breed: breed,
            sex: sex.rawValue.lowercased(),     // "female" | "male"
            birth_date: Self.dateFormatter.string(from: birthDate)
        )
        let row: AnimalRow = try await client
            .from("animals")
            .insert(payload)
            .select("id")
            .single()
            .execute()
            .value
        return CreatedAnimal(id: row.id.uuidString)
    }
}
```

> `AnimalSex.rawValue` is `"Female"` / `"Male"` (from `HerdData.swift`); `.lowercased()` yields the lowercase text the server expects.

- [ ] **Step 2: Register in the app target**

In Xcode add `CarniVision/Services/AnimalRepository.swift` to the **CarniVision** target. Verify:

```bash
grep -c "AnimalRepository.swift" CarniVision.xcodeproj/project.pbxproj
```
Expected: `>= 1`.

- [ ] **Step 3: Commit**

```bash
git add CarniVision/Services/AnimalRepository.swift CarniVision.xcodeproj
git commit -m "Add AnimalRepository for Supabase animal inserts"
```

---

## Task 13: CameraModel enrollment session + identify hooks

This task adds the model-side state. UI wiring is Task 14. Keep the existing camera pipeline untouched — we only add new published state and methods, and append crops to a buffer at the existing success point.

**Files:**
- Modify: `CarniVision/Views/Main/CameraView.swift`

- [ ] **Step 1: Add an enrollment-mode enum and published state to CameraModel**

In `CarniVision/Views/Main/CameraView.swift`, replace this exact block (the `Status`/`CaptureMode` enums plus the first published properties):

```swift
final class CameraModel: NSObject, ObservableObject {
    enum Status {
        case idle
        case authorized
        case denied
    }
```

with:

```swift
final class CameraModel: NSObject, ObservableObject {
    enum Status {
        case idle
        case authorized
        case denied
    }

    /// What this camera session is for.
    enum Purpose: Equatable {
        case identify
        case enroll(animalID: String)
    }

    /// Phase within an enrollment session.
    enum EnrollPhase: Equatable {
        case collectingMuzzles   // gathering the 5-photo burst
        case awaitingFullBody    // prompting for the single full-body shot
        case submitting          // POST /enroll in flight
        case done
        case failed
    }

    /// Number of muzzle crops an enrollment requires.
    static let enrollTarget = 5

    /// nil until configured by the presenting view.
    @Published var purpose: Purpose = .identify
    /// Crops collected so far during an enrollment burst (main-thread only).
    @Published var collectedCrops: [UIImage] = []
    /// Current enrollment phase (only meaningful when purpose == .enroll).
    @Published var enrollPhase: EnrollPhase = .collectingMuzzles
    /// Result of the most recent identify call (nil until one returns).
    @Published var identifyResult: IdentifyResult?
    /// True while an identify/enroll network call is in flight.
    @Published var isContacting = false
    /// Network/identify error message key or text for the result card.
    @Published var recognitionError: String?
```

- [ ] **Step 2: Re-arm auto-capture after a collected crop so the burst continues**

The existing `finishSuccess(crop:readout:)` sets `captureSucceeded = true` and stops. For enrollment we instead append the crop and re-arm. Replace this exact method:

```swift
    private func finishSuccess(crop: UIImage, readout: String) {
        DispatchQueue.main.async {
            self.croppedMuzzle = crop
            self.debugReadout = readout
            self.isProcessing = false
            self.captureFailed = false
            self.failureMessage = ""
            self.captureSucceeded = true
        }
    }
```

with:

```swift
    private func finishSuccess(crop: UIImage, readout: String) {
        DispatchQueue.main.async {
            self.croppedMuzzle = crop
            self.debugReadout = readout
            self.isProcessing = false
            self.captureFailed = false
            self.failureMessage = ""

            switch self.purpose {
            case .identify:
                self.captureSucceeded = true
            case .enroll:
                self.collectedCrops.append(crop)
                if self.collectedCrops.count >= Self.enrollTarget {
                    self.enrollPhase = .awaitingFullBody
                    // Stay paused; the view drives the full-body capture.
                } else {
                    // Re-arm for the next crop in the burst.
                    self.rearmForNextEnrollCrop()
                }
            }
        }
    }

    /// Clears the just-captured crop flags and re-enables auto/manual capture
    /// so the enrollment burst can collect the next muzzle.
    private func rearmForNextEnrollCrop() {
        croppedMuzzle = nil
        captureSucceeded = false
        captureFailed = false
        failureMessage = ""
        countdown = nil
        faceVisible = false
        canManualCapture = false
        debugReadout = Self.idleReadout
        resetLiveDetectionState()
    }
```

> `resetLiveDetectionState()` and `idleReadout` already exist on `CameraModel`. `rearmForNextEnrollCrop` runs on the main thread (called inside the `DispatchQueue.main.async` in `finishSuccess`).

- [ ] **Step 3: Add enrollment configuration, full-body capture, identify, and submit methods**

In `CarniVision/Views/Main/CameraView.swift`, add these methods to `CameraModel` immediately **after** the existing `finishFailure(_:)` method (i.e., just before the closing brace of the `CameraModel` class — the line `}` on what is currently line 346, before `extension CameraModel:`):

```swift
    // MARK: Enrollment / identify orchestration

    /// Switches the model into enrollment mode for a specific animal.
    func beginEnrollment(animalID: String) {
        DispatchQueue.main.async {
            self.purpose = .enroll(animalID: animalID)
            self.collectedCrops = []
            self.enrollPhase = .collectingMuzzles
            self.identifyResult = nil
            self.recognitionError = nil
            self.captureSucceeded = false
            self.captureFailed = false
        }
        resetLiveDetectionState()
        DispatchQueue.main.async { self.scanAgain() }
    }

    /// Captures the full-body photo for the current enrollment (uses lastPhoto).
    func captureFullBody() {
        // Reuse the normal capture path; processCapturedPhoto sets lastPhoto.
        // For the full-body shot we do NOT need a muzzle crop, so capture the
        // raw frame directly.
        videoQueue.async { [weak self] in
            self?.hasAutoCaptured = true
        }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning else { return }
            DispatchQueue.main.async { self.isProcessing = true }
            let delegate = PhotoCaptureDelegate { [weak self] image in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.lastPhoto = image
                    self.captureDelegate = nil
                    self.isProcessing = false
                }
            }
            self.captureDelegate = delegate
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    /// Submits the collected crops + full-body to the recognition service.
    @MainActor
    func submitEnrollment(using service: RecognitionService) async {
        guard case let .enroll(animalID) = purpose else { return }
        enrollPhase = .submitting
        isContacting = true
        recognitionError = nil
        defer { isContacting = false }

        let muzzleJpegs = collectedCrops.compactMap { ImageEncoding.muzzleJPEG($0) }
        let fullJpeg = lastPhoto.flatMap { ImageEncoding.fullBodyJPEG($0) }
        guard muzzleJpegs.count == collectedCrops.count, !muzzleJpegs.isEmpty else {
            recognitionError = RecognitionError.encoding.localizedDescription
            enrollPhase = .failed
            return
        }
        do {
            _ = try await service.enroll(animalID: animalID,
                                         muzzleJpegs: muzzleJpegs,
                                         fullJpeg: fullJpeg)
            enrollPhase = .done
        } catch {
            recognitionError = error.localizedDescription
            enrollPhase = .failed
        }
    }

    /// Runs identify on the current crop and stores the result.
    @MainActor
    func runIdentify(using service: RecognitionService) async {
        guard let crop = croppedMuzzle, let jpeg = ImageEncoding.muzzleJPEG(crop) else { return }
        isContacting = true
        recognitionError = nil
        defer { isContacting = false }
        do {
            identifyResult = try await service.identify(jpegData: jpeg)
        } catch {
            recognitionError = error.localizedDescription
        }
    }

    /// Clears identify/enroll state and re-arms for another scan.
    func resetRecognition() {
        DispatchQueue.main.async {
            self.identifyResult = nil
            self.recognitionError = nil
            self.collectedCrops = []
            self.enrollPhase = .collectingMuzzles
        }
        scanAgain()
    }
```

> `videoQueue`, `sessionQueue`, `photoOutput`, `captureDelegate`, `hasAutoCaptured`, `isConfigured`, `lastPhoto`, `isProcessing` are all existing private members of `CameraModel` referenced here from within the class, so this compiles. `RecognitionService`, `IdentifyResult`, `RecognitionError`, `ImageEncoding` come from Tasks 7/9/10.

- [ ] **Step 4: Build to confirm the model compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views/Main/CameraView.swift
git commit -m "Add enrollment session and identify orchestration to CameraModel"
```

---

## Task 14: Camera UI — enrollment progress, full-body prompt, identify result card

**Files:**
- Modify: `CarniVision/Views/Main/CameraView.swift`
- Modify: `CarniVision/Models/Localization.swift`

- [ ] **Step 1: Add camera/recognition localization strings (EN)**

In `CarniVision/Models/Localization.swift`, in the `.english` dictionary, replace this exact line:

```swift
            "camera.done": "Done",
```

with:

```swift
            "camera.done": "Done",
            "camera.enroll.progress": "Muzzle %d of %d",
            "camera.enroll.fullPrompt": "Now capture the full animal",
            "camera.enroll.captureFull": "Capture full body",
            "camera.enroll.submitting": "Enrolling…",
            "camera.enroll.success": "Animal enrolled",
            "camera.enroll.failed": "Enrollment failed",
            "camera.enroll.retry": "Retry enrollment",
            "camera.identify.identified": "Identified",
            "camera.identify.unknown": "Animal not recognized",
            "camera.identify.score": "Confidence %.0f%%",
            "camera.identify.enroll": "Enroll this animal",
            "camera.identify.waking": "Waking up recognizer…",
            "camera.identify.offline": "Network unavailable. Try again.",
            "camera.identify.retry": "Try again",
```

- [ ] **Step 2: Add camera/recognition localization strings (TR)**

In the `.turkish` dictionary, replace this exact line:

```swift
            "camera.done": "Tamam",
```

with:

```swift
            "camera.done": "Tamam",
            "camera.enroll.progress": "Burun %d / %d",
            "camera.enroll.fullPrompt": "Şimdi hayvanın tamamını çekin",
            "camera.enroll.captureFull": "Tüm vücudu çek",
            "camera.enroll.submitting": "Kaydediliyor…",
            "camera.enroll.success": "Hayvan kaydedildi",
            "camera.enroll.failed": "Kayıt başarısız",
            "camera.enroll.retry": "Kaydı tekrar dene",
            "camera.identify.identified": "Tanımlandı",
            "camera.identify.unknown": "Hayvan tanınmadı",
            "camera.identify.score": "Güven %%%.0f",
            "camera.identify.enroll": "Bu hayvanı kaydet",
            "camera.identify.waking": "Tanıyıcı uyandırılıyor…",
            "camera.identify.offline": "Ağ kullanılamıyor. Tekrar deneyin.",
            "camera.identify.retry": "Tekrar dene",
```

> `%%%.0f` in Turkish renders a literal `%` then the number (e.g. `%92`); `%.0f%%` in English renders `92%`. Both pass one `Double` arg.

- [ ] **Step 3: Give CameraScreen a purpose + injected service, and identify after capture**

In `CarniVision/Views/Main/CameraView.swift`, replace this exact block:

```swift
struct CameraScreen: View {
    var onClose: () -> Void = {}

    @StateObject private var model = CameraModel()
    @ObservedObject private var lang = LanguageManager.shared
    @State private var flash = false
    @State private var showHelp = false
    @State private var showResult = false
```

with:

```swift
struct CameraScreen: View {
    var onClose: () -> Void = {}
    /// When set, the camera runs an enrollment session for this animal.
    var enrollAnimalID: String? = nil
    /// Called when an unknown identify result's "Enroll" button is tapped.
    var onRequestEnroll: () -> Void = {}

    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @StateObject private var model = CameraModel()
    @ObservedObject private var lang = LanguageManager.shared
    @State private var flash = false
    @State private var showHelp = false
    @State private var showResult = false
```

- [ ] **Step 4: Configure the model on appear and react to a successful capture**

Replace this exact block (the `.onAppear`/`.onDisappear`/`.onChange` chain):

```swift
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.captureSucceeded) { _, succeeded in
            if succeeded {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        }
        .onChange(of: model.captureFailed) { _, failed in
            if failed {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
```

with:

```swift
        .onAppear {
            model.start()
            if let id = enrollAnimalID {
                model.beginEnrollment(animalID: id)
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.captureSucceeded) { _, succeeded in
            guard succeeded else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            // Identify mode: as soon as a crop is captured, ask the server.
            if enrollAnimalID == nil {
                Task { await model.runIdentify(using: recognition) }
            }
        }
        .onChange(of: model.captureFailed) { _, failed in
            if failed {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
        .onChange(of: model.enrollPhase) { _, phase in
            if phase == .awaitingFullBody {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
            }
        }
```

- [ ] **Step 5: Add the enrollment + identify overlays to the ZStack**

Replace this exact block (the tail of the main `ZStack`, where the result overlay is shown):

```swift
            overlayControls

            if model.showsResultOverlay {
                resultOverlay
            }
        }
```

with:

```swift
            overlayControls

            if model.showsResultOverlay {
                resultOverlay
            }

            if enrollAnimalID != nil {
                enrollmentOverlay
            }

            if enrollAnimalID == nil, model.identifyResult != nil || model.recognitionError != nil {
                identifyOverlay
            }

            if !recognition.isReady {
                wakingBanner
            }
        }
```

- [ ] **Step 6: Add the overlay view builders**

In `CarniVision/Views/Main/CameraView.swift`, add these computed views to `CameraScreen` immediately **after** the existing `resultOverlay` computed property (before `private func capture()`):

```swift
    // MARK: Enrollment overlay

    @ViewBuilder
    private var enrollmentOverlay: some View {
        switch model.enrollPhase {
        case .collectingMuzzles:
            VStack {
                Spacer()
                Text(lang.t("camera.enroll.progress", model.collectedCrops.count, CameraModel.enrollTarget))
                    .font(CarniFont.semibold(16))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(Capsule().fill(CarniColors.purple.opacity(0.85)))
                    .padding(.bottom, 160)
            }
            .allowsHitTesting(false)

        case .awaitingFullBody:
            VStack(spacing: 16) {
                Spacer()
                Text(lang.t("camera.enroll.fullPrompt"))
                    .font(CarniFont.semibold(17))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                Button {
                    model.captureFullBody()
                    Task {
                        // Give the capture a beat to set lastPhoto, then submit.
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        await model.submitEnrollment(using: recognition)
                    }
                } label: {
                    Text(lang.t("camera.enroll.captureFull"))
                        .font(CarniFont.semibold(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(CarniColors.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }

        case .submitting:
            recognitionScrim {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(lang.t("camera.enroll.submitting"))
                        .font(CarniFont.semibold(16)).foregroundStyle(.white)
                }
            }

        case .done:
            recognitionScrim {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54)).foregroundStyle(CarniColors.successGreen)
                    Text(lang.t("camera.enroll.success"))
                        .font(CarniFont.bold(20)).foregroundStyle(.white)
                    Button { onClose() } label: {
                        Text(lang.t("camera.done"))
                            .font(CarniFont.semibold(16)).foregroundStyle(CarniColors.purple)
                            .padding(.vertical, 12).padding(.horizontal, 40)
                            .background(CarniColors.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .failed:
            recognitionScrim {
                VStack(spacing: 16) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 54)).foregroundStyle(.red)
                    Text(lang.t("camera.enroll.failed"))
                        .font(CarniFont.bold(20)).foregroundStyle(.white)
                    if let err = model.recognitionError {
                        Text(err).font(CarniFont.regular(13)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    Button {
                        Task { await model.submitEnrollment(using: recognition) }
                    } label: {
                        Text(lang.t("camera.enroll.retry"))
                            .font(CarniFont.semibold(16)).foregroundStyle(CarniColors.purple)
                            .padding(.vertical, 12).padding(.horizontal, 40)
                            .background(CarniColors.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Identify overlay

    @ViewBuilder
    private var identifyOverlay: some View {
        recognitionScrim {
            VStack(spacing: 16) {
                if let result = model.identifyResult {
                    if result.isIdentified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 50)).foregroundStyle(CarniColors.successGreen)
                        Text(result.name ?? lang.t("camera.identify.identified"))
                            .font(CarniFont.bold(22)).foregroundStyle(.white)
                        Text(lang.t("camera.identify.score", result.score * 100))
                            .font(CarniFont.regular(15)).foregroundStyle(.white.opacity(0.85))
                    } else {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 50)).foregroundStyle(.orange)
                        Text(lang.t("camera.identify.unknown"))
                            .font(CarniFont.bold(20)).foregroundStyle(.white)
                        Button { onRequestEnroll() } label: {
                            Text(lang.t("camera.identify.enroll"))
                                .font(CarniFont.semibold(16)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13).background(CarniColors.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain).padding(.horizontal, 24)
                    }
                } else if model.recognitionError != nil {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 44)).foregroundStyle(.white)
                    Text(lang.t("camera.identify.offline"))
                        .font(CarniFont.semibold(16)).foregroundStyle(.white)
                }

                Button { model.resetRecognition() } label: {
                    Text(lang.t("camera.scanAgain"))
                        .font(CarniFont.semibold(15)).foregroundStyle(.white.opacity(0.9))
                        .padding(.vertical, 10).padding(.horizontal, 30)
                        .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var wakingBanner: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().tint(.white).scaleEffect(0.8)
                Text(lang.t("camera.identify.waking"))
                    .font(CarniFont.semibold(13)).foregroundStyle(.white)
            }
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(.top, 70)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    /// Dim background wrapper shared by the recognition overlays.
    @ViewBuilder
    private func recognitionScrim<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            content()
                .padding(24)
        }
        .transition(.opacity)
    }
```

> All referenced symbols exist: `CarniColors`, `CarniFont`, `lang.t(_:)` and `lang.t(_:_:)` (variadic), `model.identifyResult`, `model.recognitionError`, `model.enrollPhase`, `model.collectedCrops`, `CameraModel.enrollTarget`, `model.isReady` is on the injected `recognition` (a `CloudRunRecognitionService`), `model.captureFullBody()`, `model.submitEnrollment(using:)`, `model.runIdentify(using:)`, `model.resetRecognition()`.

- [ ] **Step 7: Build to confirm UI compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add CarniVision/Views/Main/CameraView.swift CarniVision/Models/Localization.swift
git commit -m "Add enrollment progress, full-body prompt, and identify result UI"
```

---

## Task 15: AddAnimalView → create row → present enrollment camera

**Files:**
- Modify: `CarniVision/Views/Main/AddAnimalView.swift`

- [ ] **Step 1: Inject auth, add repository + presentation state**

In `CarniVision/Views/Main/AddAnimalView.swift`, replace this exact block:

```swift
struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var weightText = ""
    @State private var muzzleScanned = false
    @State private var showSavedToast = false
```

with:

```swift
struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared

    private let repository = AnimalRepository()

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var weightText = ""
    @State private var muzzleScanned = false
    @State private var showSavedToast = false

    @State private var isSaving = false
    @State private var saveError: String?
    /// Set to the new animal id to trigger the enrollment camera.
    @State private var enrollAnimalID: String?
```

- [ ] **Step 2: Replace the save button to show a saving state and inline error**

Replace this exact block:

```swift
    private var saveButton: some View {
        Button(action: save) {
            Text(lang.t("add.save"))
                .font(CarniFont.bold(16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canSave ? CarniColors.purple : CarniColors.purple.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }
```

with:

```swift
    private var saveButton: some View {
        VStack(spacing: 10) {
            if let saveError {
                Text(saveError)
                    .font(CarniFont.regular(13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: save) {
                Text(isSaving ? lang.t("camera.enroll.submitting") : lang.t("add.save"))
                    .font(CarniFont.bold(16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canSave && !isSaving ? CarniColors.purple : CarniColors.purple.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave || isSaving)
        }
    }
```

- [ ] **Step 3: Present the enrollment camera as a full-screen cover**

Replace this exact block (the root `ZStack` modifiers — currently the `ZStack` closes with `}` and has no trailing modifiers other than its contents). Replace:

```swift
            if showSavedToast {
                savedToast
            }
        }
    }
```

with:

```swift
            if showSavedToast {
                savedToast
            }
        }
        .fullScreenCover(item: $enrollAnimalID) { animalID in
            CameraScreen(
                onClose: {
                    // Mark local registration on success path completion.
                    store.markLastAddedMuzzleRegistered()
                    enrollAnimalID = nil
                },
                enrollAnimalID: animalID
            )
        }
    }
```

> `String` is not `Identifiable`. Add this small conformance helper at the bottom of the file (after the `FormField` struct) so `fullScreenCover(item:)` accepts a `String?`:

```swift
extension String: Identifiable {
    public var id: String { self }
}
```

- [ ] **Step 4: Rewrite `save()` to create the row then launch enrollment**

Replace this exact method:

```swift
    private func save() {
        store.addAnimal(
            name: name.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces),
            breed: breed,
            sex: sex,
            birthDate: birthDate,
            initialWeightKg: Double(weightText.replacingOccurrences(of: ",", with: ".")),
            muzzleRegistered: muzzleScanned
        )

        name = ""
        tag = ""
        weightText = ""
        muzzleScanned = false

        withAnimation(.spring(duration: 0.35)) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.3)) { showSavedToast = false }
        }
    }
}
```

with:

```swift
    private func save() {
        guard let ownerID = auth.userID else {
            saveError = lang.t("auth.error.generic")
            return
        }
        saveError = nil
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let created = try await repository.create(
                    ownerID: ownerID,
                    name: trimmedName,
                    tag: trimmedTag,
                    breed: breed,
                    sex: sex,
                    birthDate: birthDate
                )
                // Keep the in-memory herd list in sync (muzzleRegistered flips
                // to true only after a successful enroll — see markLast…).
                store.addAnimal(
                    name: trimmedName,
                    tag: trimmedTag,
                    breed: breed,
                    sex: sex,
                    birthDate: birthDate,
                    initialWeightKg: Double(weightText.replacingOccurrences(of: ",", with: ".")),
                    muzzleRegistered: false
                )
                await MainActor.run {
                    isSaving = false
                    name = ""
                    tag = ""
                    weightText = ""
                    muzzleScanned = false
                    enrollAnimalID = created.id   // launches the enrollment camera
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}
```

- [ ] **Step 5: Add the HerdStore helper used on enrollment completion**

In `CarniVision/Models/HerdData.swift`, add this method to `HerdStore` immediately **after** the existing `addAnimal(...)` method (before the `// MARK: Date helpers` comment):

```swift
    /// Flips the most-recently-added animal's muzzle flag to true (called when
    /// the enrollment camera completes successfully). MVP-local only.
    func markLastAddedMuzzleRegistered() {
        guard !animals.isEmpty else { return }
        animals[0].muzzleRegistered = true
        animals[0].lastScanned = Date()
    }
```

> New animals are inserted at index 0 (`animals.insert(animal, at: 0)`), so index 0 is the just-added animal.

- [ ] **Step 6: Build to confirm wiring compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add CarniVision/Views/Main/AddAnimalView.swift CarniVision/Models/HerdData.swift
git commit -m "Wire AddAnimal save to Supabase insert and enrollment camera"
```

---

## Task 16: Connect the identify-unknown "Enroll" path

The identify result card's Enroll button (`onRequestEnroll`) must create a row and re-launch the camera in enrollment mode. The camera tab in `MainTabView` presents `CameraScreen` for identify; we let it surface an enroll request up to a coordinator state.

**Files:**
- Modify: `CarniVision/Views/Main/MainTabView.swift`

- [ ] **Step 1: Add enroll-from-identify coordination to MainTabView**

In `CarniVision/Views/Main/MainTabView.swift`, replace the entire contents:

```swift
import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home
    @StateObject private var store = HerdStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            CarniColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(store)

            if selected != .camera {
                CarniTabBar(selected: $selected)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(onSeeAllAnimals: { selected = .animals })
        case .animals:
            AnimalsScreen()
        case .camera:
            CameraScreen(onClose: { selected = .home })
        case .addAnimal:
            AddAnimalScreen()
        case .settings:
            SettingsScreen()
        }
    }
}
```

with:

```swift
import SwiftUI

struct MainTabView: View {
    @State private var selected: AppTab = .home
    @StateObject private var store = HerdStore()
    /// When set from an "unknown" identify result, the camera tab redirects
    /// to the Add Animal flow so the operator can enroll the new animal.
    @State private var pendingEnrollRequest = false

    var body: some View {
        ZStack(alignment: .bottom) {
            CarniColors.appBackground
                .ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(store)

            if selected != .camera {
                CarniTabBar(selected: $selected)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .home:
            HomeScreen(onSeeAllAnimals: { selected = .animals })
        case .animals:
            AnimalsScreen()
        case .camera:
            CameraScreen(
                onClose: { selected = .home },
                onRequestEnroll: { selected = .addAnimal }
            )
        case .addAnimal:
            AddAnimalScreen()
        case .settings:
            SettingsScreen()
        }
    }
}
```

> The unknown-animal Enroll button routes the operator to the Add Animal form (which creates a row, then launches enrollment per Task 15). `pendingEnrollRequest` is reserved for a future auto-prefill; it is unused now and may be omitted — keep `selected = .addAnimal` as the wiring.

- [ ] **Step 2: Remove the unused state to avoid a warning**

Replace this exact block:

```swift
    @State private var selected: AppTab = .home
    @StateObject private var store = HerdStore()
    /// When set from an "unknown" identify result, the camera tab redirects
    /// to the Add Animal flow so the operator can enroll the new animal.
    @State private var pendingEnrollRequest = false
```

with:

```swift
    @State private var selected: AppTab = .home
    @StateObject private var store = HerdStore()
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add CarniVision/Views/Main/MainTabView.swift
git commit -m "Route unknown-identify enroll button to Add Animal flow"
```

---

## Task 17: Update SwiftUI previews to inject mocks

Any preview that renders `RootView`, `LandingView`, `SignInForm`, `SignUpForm`, `AddAnimalScreen`, or `CameraScreen` now needs `AuthService` and `CloudRunRecognitionService`/mock in the environment.

**Files:**
- Modify: any `#Preview` blocks that fail to compile after the wiring (search first).

- [ ] **Step 1: Find previews that need injection**

```bash
grep -rln "#Preview\|PreviewProvider" CarniVision/Views/
```
Expected: a list of files. For each that renders one of the views above, add the environment objects.

- [ ] **Step 2: Add a preview helper for the recognition environment**

If a preview renders `CameraScreen`, it needs a `CloudRunRecognitionService` in the environment (the concrete type used by `@EnvironmentObject`). Add this preview-only factory once, e.g. at the bottom of `CarniVision/Views/Main/CameraView.swift`:

```swift
#if DEBUG
extension CloudRunRecognitionService {
    /// A ready-state service for previews; never hits the network because
    /// previews don't trigger capture.
    static var preview: CloudRunRecognitionService {
        let s = CloudRunRecognitionService(
            baseURL: URL(string: "https://preview.invalid")!,
            tokenProvider: { "preview-token" }
        )
        s.isReady = true
        return s
    }
}
#endif
```

- [ ] **Step 3: Inject into each failing preview**

For each preview that renders an auth/camera view, wrap it, for example:

```swift
#Preview {
    CameraScreen()
        .environmentObject(CloudRunRecognitionService.preview)
}
```

and for auth/root previews:

```swift
#Preview {
    RootView()
        .environmentObject(AuthService())
}
```

> Only edit previews that actually exist and fail to build; do not invent new preview blocks.

- [ ] **Step 4: Build (Debug) to confirm previews compile**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add CarniVision/Views
git commit -m "Inject mock services into SwiftUI previews"
```

---

## Task 18: Full test + build gate

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test suite**

```bash
xcodebuild test -project CarniVision.xcodeproj -scheme CarniVision -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **` with `AuthServiceTests` (3), `MultipartFormDataTests` (5), `RecognitionDecodingTests` (4) all passing.

- [ ] **Step 2: Confirm a clean release build**

```bash
xcodebuild build -project CarniVision.xcodeproj -scheme CarniVision -configuration Release -destination 'generic/platform=iOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (This is the build that goes to the phone.)

- [ ] **Step 3: Commit (if any incidental fixes were needed)**

```bash
git add -A
git commit -m "Fix build/test issues found in full gate" || echo "nothing to commit"
```

---

## Task 19: On-device manual test checklist

**Files:** none (manual verification on hardware).

Prerequisite: `SUPABASE_ANON_KEY` filled in `Info.plist` (Task 2 / README), and a pilot user `pilot-test@carnivision.local` exists in Supabase Auth with a known password.

- [ ] **Step 1: Build & run to a physical iPhone** (team `Z23895JP8U`). Confirm the app launches and shows the Landing screen, and that within ~90 s the "Waking up recognizer…" banner disappears (warmUp succeeded).

- [ ] **Step 2: Sign in** with `pilot-test@carnivision.local`. Confirm the app transitions to `MainTabView` (session gating works). Force-quit and relaunch — confirm you stay signed in (session persisted).

- [ ] **Step 3: Enroll.** Add tab → fill name/tag/breed/sex/birth date → Save. Confirm the enrollment camera opens, the burst auto-collects "Muzzle 1/5 … 5/5", then prompts "Now capture the full animal". Capture full body → confirm "Enrolling…" then "Animal enrolled".

- [ ] **Step 4: Verify in Supabase dashboard.** Confirm a row in `animals` (owner = the pilot user's UID, sex lowercased, birth_date ISO), 5 rows in `embeddings` for that `animal_id`, and Storage objects under `muzzles/{owner}/{animal_id}/muzzle/` (5) and `…/full/` (1).

- [ ] **Step 5: Identify (known).** Camera tab → point at the same muzzle → confirm the identify card shows the animal name + confidence score.

- [ ] **Step 6: Identify (unknown).** Point at an un-enrolled animal → confirm the "Animal not recognized" card + a tappable "Enroll this animal" button that routes to the Add Animal form.

- [ ] **Step 7: Offline.** Disable network → trigger identify → confirm the offline/retry card appears, and that the Animals tab (HerdStore) still renders the herd list.

- [ ] **Step 8: Record results** in the PR description (which steps passed, any anomalies, the exact supabase-swift version resolved).

---

## Self-Review

**1. Spec coverage**

| Spec section | Task(s) |
|---|---|
| §1 SupabaseClientProvider (SPM add, Config keys, singleton) | Tasks 1, 2, 3 |
| §2 AuthService (signIn/signUp/signOut/session/accessToken; RootView gating; inline errors; loading; localized) | Tasks 4, 5, 6 |
| §3 AnimalRepository (insert with explicit owner; field mapping; returns id) | Task 12, used in Task 15 |
| §4 RecognitionService protocol + IdentifyResult/EnrollResult/Candidate + multipart encoder + CloudRunRecognitionService (Bearer, 90 s, JPEG 0.85, full ≤2048) + Mock | Tasks 7, 8, 9, 10 |
| §Flows Enrollment (5 crops + full body, single enroll, success/failure, HerdStore flag) | Tasks 13, 14, 15 |
| §Flows Identify (encode crop, identify, identified/unknown card, Enroll button) | Tasks 13, 14, 16 |
| §Error handling (cold start warmUp/isReady banner, offline retry, enroll retry, detector gate unchanged) | Tasks 11, 13, 14 |
| §Image encoding rules (0.85; full ≤2048) | Task 9 |
| §Testing unit (multipart field names, Bearer, decoding; auth session/error) | Tasks 4, 8, 10 |
| §Testing on-device manual plan | Task 19 |
| §Testing previews (inject mock) | Task 17 |
| §Operator inputs (anon key, sign-up decision) | Task 2 (README) |

No spec requirement is left without a task.

**2. Placeholder scan** — No `TBD`/`TODO`/`implement later`/"similar to Task N"/"add error handling" left; every code step contains complete code. The only intentional placeholder is the literal `REPLACE_WITH_SUPABASE_ANON_KEY` Info.plist value, which is the operator input the spec requires (guarded by `AppConfig.supabaseAnonKey`'s fatalError).

**3. Type consistency** — Verified across tasks:
- `AuthService` exposes `identity`, `accessToken`, `userID`, `errorMessage`, `isWorking`, `signIn`, `signUp`, `signOut`, `bootstrap` — used consistently in Tasks 6, 11, 15.
- `RecognitionService` methods `warmUp()`, `identify(jpegData:)`, `enroll(animalID:muzzleJpegs:fullJpeg:)` — identical in protocol (Task 9), `CloudRunRecognitionService` (Task 10), `MockRecognitionService` (Task 9), and call sites (Task 13).
- `IdentifyResult`/`EnrollResult`/`Candidate` field names and `CodingKeys` (Task 7) match the server JSON (`server/app/schemas.py`) and the decoding tests (Task 10).
- `MultipartFormData` API (`init(boundary:)`, `contentType`, `appendField`, `appendFile`, `finalizedBody`) identical in tests (Task 8) and service (Task 10).
- `CameraModel` additions (`Purpose`, `EnrollPhase`, `enrollTarget`, `collectedCrops`, `beginEnrollment`, `captureFullBody`, `submitEnrollment(using:)`, `runIdentify(using:)`, `resetRecognition`, `identifyResult`, `recognitionError`) defined in Task 13 and consumed in Task 14.
- `AnimalRepository.create(ownerID:name:tag:breed:sex:birthDate:)` → `CreatedAnimal.id` defined in Task 12, called in Task 15.
- Multipart field names match the server: `image` (identify), `animal_id` + `images` + `full_images` (enroll) — asserted in Task 10 tests.

All consistent.
