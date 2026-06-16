# Server Status Pill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-warm the scale-to-zero embedder on user activity (sign-in + app foreground) instead of only at launch, and surface a non-blocking status pill that is silent when healthy and only appears when the server is connecting or offline.

**Architecture:** `CloudRunRecognitionService` gains a `ServerStatus` enum (`unknown / connecting / online / offline`); `isReady` becomes derived from it. `warmUp()` drives the states and debounces re-checks via an injectable clock. `MainTabView` (the signed-in shell) triggers `warmUp()` on appear (sign-in / launch-with-session) and on `scenePhase == .active` (foreground return), and overlays a `ServerStatusPill` that renders only while connecting or offline. The launch-time warmup in `AgriVisionApp` is removed.

**Tech Stack:** SwiftUI, supabase-swift, XCTest with `MockURLProtocol`. Spec: `docs/superpowers/specs/2026-06-13-server-status-pill-design.md`.

---

## File Structure

- **Modify** `AgriVision/Services/CloudRunRecognitionService.swift` — add `ServerStatus` enum, `@Published status`, derived `isReady`, injectable `now` clock, debounced state-driving `warmUp()`.
- **Modify** `AgriVision/AgriVisionApp.swift:28-31` — drop the launch-time `warmUp()` call (keep `auth.bootstrap()`).
- **Modify** `AgriVision/Models/Localization.swift` — add `server.status.connecting` / `server.status.offline` keys in the English and Turkish tables.
- **Modify** `AgriVision/Views/Main/MainTabView.swift` — inject `recognition`, observe `scenePhase`, call `warmUp()` on appear + foreground, overlay the pill, and define the private `ServerStatusPill` view.
- **Create** `AgriVisionTests/ServerStatusTests.swift` — unit tests for state transitions and debounce. (Test target is filesystem-synchronized, so this auto-registers — no pbxproj edit.)

**pbxproj note:** All new *app-target* types live inside existing files (`ServerStatus` in `CloudRunRecognitionService.swift`, `ServerStatusPill` in `MainTabView.swift`), so NO manual pbxproj registration is required. Only the test file is new, and the test target auto-syncs.

---

## Task 1: ServerStatus enum + derived isReady + injectable clock

**Files:**
- Modify: `AgriVision/Services/CloudRunRecognitionService.swift`
- Modify: `AgriVision/Views/Main/CameraView.swift:1515` (the `.preview` helper assigns `isReady`, which becomes read-only)
- Test: `AgriVisionTests/ServerStatusTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `AgriVisionTests/ServerStatusTests.swift`:

```swift
import XCTest
@testable import AgriVision

/// Mutable clock so debounce windows can be advanced deterministically.
final class TestClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { self.now = start }
}

@MainActor
final class ServerStatusTests: XCTestCase {
    private func makeService(clock: TestClock = TestClock()) -> CloudRunRecognitionService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CloudRunRecognitionService(
            baseURL: URL(string: "https://embedder.example.com")!,
            session: session,
            tokenProvider: { "jwt-token" },
            now: { clock.now }
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    func testStatusDefaultsToUnknownAndIsReadyDerives() {
        let service = makeService()
        XCTAssertEqual(service.status, .unknown)
        XCTAssertFalse(service.isReady)

        service.status = .online
        XCTAssertTrue(service.isReady)

        service.status = .offline
        XCTAssertFalse(service.isReady)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AgriVisionTests/ServerStatusTests/testStatusDefaultsToUnknownAndIsReadyDerives`
Expected: FAIL to compile — `ServerStatus`, the `now:` init parameter, and `status` do not exist yet.

- [ ] **Step 3: Add the enum, status property, derived isReady, and clock**

In `AgriVision/Services/CloudRunRecognitionService.swift`, add the enum just above the class declaration (after the `import Foundation` line):

```swift
/// Lifecycle of the scale-to-zero embedder as the app understands it.
enum ServerStatus { case unknown, connecting, online, offline }
```

Replace the existing `@Published var isReady = false` line with:

```swift
/// Drives the status pill and the camera readiness gate.
@Published var status: ServerStatus = .unknown
/// True once /health reports the model is loaded.
var isReady: Bool { status == .online }
```

Add a stored clock and debounce window alongside the other private lets:

```swift
/// Injected so tests can advance time; production uses the wall clock.
private let now: () -> Date
/// Skip re-pinging if we confirmed online within this window (< container idle timeout).
private let debounceWindow: TimeInterval = 120
/// Timestamp of the last confirmed-online /health.
private var lastOnlineCheck: Date?
```

Update the initializer to accept and store `now` (default = wall clock):

```swift
init(baseURL: URL, session: URLSession = .shared,
     tokenProvider: @escaping () async -> String?,
     now: @escaping () -> Date = Date.init) {
    self.baseURL = baseURL
    self.session = session
    self.tokenProvider = tokenProvider
    self.now = now
}
```

- [ ] **Step 4: Fix the preview helper that assigned the now-read-only isReady**

`isReady` is now a computed get-only property, so `CameraView.swift:1515` no longer compiles. In `AgriVision/Views/Main/CameraView.swift`, in the `static var preview` helper, change:

```swift
        s.isReady = true
```

to:

```swift
        s.status = .online
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AgriVisionTests/ServerStatusTests/testStatusDefaultsToUnknownAndIsReadyDerives`
Expected: PASS (and the project compiles — the preview fix is required for the test target to build).

- [ ] **Step 6: Commit**

```bash
git add AgriVision/Services/CloudRunRecognitionService.swift AgriVision/Views/Main/CameraView.swift AgriVisionTests/ServerStatusTests.swift
git commit -m "feat(ios): add ServerStatus enum and derive isReady"
```

---

## Task 2: warmUp drives the states with debounce

**Files:**
- Modify: `AgriVision/Services/CloudRunRecognitionService.swift` (the `warmUp()` method)
- Test: `AgriVisionTests/ServerStatusTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these methods to `ServerStatusTests` (the `MockURLProtocol` from `RecognitionDecodingTests.swift` is shared in the test target). The helpers build `/health` responses and count network hits:

```swift
private func healthResponse(modelLoaded: Bool, status: Int = 200) {
    MockURLProtocol.requestHandler = { request in
        let json = "{\"status\":\"ok\",\"model_loaded\":\(modelLoaded)}".data(using: .utf8)!
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        return (resp, json)
    }
}

func testWarmUpSuccessSetsOnline() async {
    let service = makeService()
    healthResponse(modelLoaded: true)
    await service.warmUp()
    XCTAssertEqual(service.status, .online)
    XCTAssertTrue(service.isReady)
}

func testWarmUpModelNotLoadedSetsOffline() async {
    let service = makeService()
    healthResponse(modelLoaded: false)
    await service.warmUp()
    XCTAssertEqual(service.status, .offline)
}

func testWarmUpHTTPErrorSetsOffline() async {
    let service = makeService()
    healthResponse(modelLoaded: true, status: 503)
    await service.warmUp()
    XCTAssertEqual(service.status, .offline)
}

func testWarmUpTransportErrorSetsOffline() async {
    let service = makeService()
    MockURLProtocol.requestHandler = { _ in throw NSError(domain: "net", code: -1009) }
    await service.warmUp()
    XCTAssertEqual(service.status, .offline)
}

func testDebounceSkipsWithinWindow() async {
    let clock = TestClock()
    let service = makeService(clock: clock)

    healthResponse(modelLoaded: true)          // first call -> online
    await service.warmUp()
    XCTAssertEqual(service.status, .online)

    // Within 120s, a second call must NOT touch the network: prove it by
    // arming a handler that would flip to offline; status must stay online.
    clock.now = Date(timeIntervalSince1970: 60)
    healthResponse(modelLoaded: false)         // would set offline IF called
    await service.warmUp()
    XCTAssertEqual(service.status, .online, "debounced call must not re-ping")
}

func testDebounceReChecksAfterWindow() async {
    let clock = TestClock()
    let service = makeService(clock: clock)

    healthResponse(modelLoaded: true)
    await service.warmUp()
    XCTAssertEqual(service.status, .online)

    clock.now = Date(timeIntervalSince1970: 121)  // past the 120s window
    healthResponse(modelLoaded: false)
    await service.warmUp()
    XCTAssertEqual(service.status, .offline, "after the window it must re-ping")
}

func testDebounceAlwaysChecksWhenNotOnline() async {
    let service = makeService()
    healthResponse(modelLoaded: true, status: 503)  // -> offline
    await service.warmUp()
    XCTAssertEqual(service.status, .offline)

    healthResponse(modelLoaded: true)               // not online -> must re-ping
    await service.warmUp()
    XCTAssertEqual(service.status, .online)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AgriVisionTests/ServerStatusTests`
Expected: the new `testWarmUp*` / `testDebounce*` cases FAIL (current `warmUp()` sets `isReady` on a removed property path and never sets `.offline` / debounces).

- [ ] **Step 3: Replace warmUp with the state-driving, debounced version**

In `AgriVision/Services/CloudRunRecognitionService.swift`, replace the entire `warmUp()` method with:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AgriVisionTests/ServerStatusTests`
Expected: PASS (all `ServerStatusTests` green).

- [ ] **Step 5: Commit**

```bash
git add AgriVision/Services/CloudRunRecognitionService.swift AgriVisionTests/ServerStatusTests.swift
git commit -m "feat(ios): drive warmUp through ServerStatus with debounce"
```

---

## Task 3: Localization strings for the pill

**Files:**
- Modify: `AgriVision/Models/Localization.swift`

- [ ] **Step 1: Add English keys**

In `AgriVision/Models/Localization.swift`, in the `.english` table, immediately after the line `"camera.identify.retry": "Try again",` (around line 201) add:

```swift
            "server.status.connecting": "Connecting…",
            "server.status.offline": "Server offline — tap to retry",
```

- [ ] **Step 2: Add Turkish keys**

In the `.turkish` table, immediately after the line `"camera.identify.retry": "Tekrar dene",` (around line 386) add:

```swift
            "server.status.connecting": "Bağlanılıyor…",
            "server.status.offline": "Sunucu çevrimdışı — yeniden denemek için dokunun",
```

- [ ] **Step 3: Build to verify the table still compiles**

Run: `xcodebuild build -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AgriVision/Models/Localization.swift
git commit -m "feat(ios): add server status pill strings (en/tr)"
```

---

## Task 4: Wire triggers + render the pill, drop launch warmup

**Files:**
- Modify: `AgriVision/AgriVisionApp.swift:28-31`
- Modify: `AgriVision/Views/Main/MainTabView.swift`

This task is UI wiring verified by build + on-device behavior (the trigger/pill logic itself is covered by Tasks 1–2).

- [ ] **Step 1: Remove the launch-time warmup**

In `AgriVision/AgriVisionApp.swift`, change the `.task` block (lines 28-31) from:

```swift
                .task {
                    await auth.bootstrap()
                    await recognition.warmUp()
                }
```

to:

```swift
                .task {
                    // Warmup now happens on user activity (MainTabView), not at launch,
                    // so a backgrounded-then-resumed app re-checks the sleeping container.
                    await auth.bootstrap()
                }
```

- [ ] **Step 2: Inject recognition + scenePhase into MainTabView**

In `AgriVision/Views/Main/MainTabView.swift`, add these properties at the top of `struct MainTabView` (after `@EnvironmentObject private var auth: AuthService`):

```swift
    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var lang = LanguageManager.shared
```

- [ ] **Step 3: Trigger warmUp on appear and on foreground**

In the same file, replace the existing modifier:

```swift
        .task { await store.load() }
```

with:

```swift
        // Runs on sign-in and on each cold launch with a restored session.
        .task {
            await store.load()
            await recognition.warmUp()
        }
        // Re-warm when the app returns to the foreground: the scale-to-zero
        // container may have slept while the app was backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await recognition.warmUp() } }
        }
```

- [ ] **Step 4: Overlay the pill**

In the same file, add the pill as the top-most layer of the root `ZStack`. Immediately before the closing brace of the `ZStack(alignment: .bottom) { ... }` (after the `if selected != .camera { AgriTabBar(...) }` block), add:

```swift
            ServerStatusPill(status: recognition.status,
                             lang: lang,
                             onRetry: { Task { await recognition.warmUp() } })
                .frame(maxHeight: .infinity, alignment: .top)
```

- [ ] **Step 5: Define the ServerStatusPill view**

In the same file, after the closing brace of `struct MainTabView`, add:

```swift
/// Floating status indicator. Silent when the server is healthy (online/unknown);
/// shows an amber "connecting" pill or a red tap-to-retry "offline" pill otherwise.
private struct ServerStatusPill: View {
    let status: ServerStatus
    @ObservedObject var lang: LanguageManager
    let onRetry: () -> Void

    var body: some View {
        switch status {
        case .connecting:
            pill(text: lang.t("server.status.connecting"),
                 background: Color.orange.opacity(0.92),
                 showsSpinner: true)
                .allowsHitTesting(false)
        case .offline:
            Button(action: onRetry) {
                pill(text: lang.t("server.status.offline"),
                     background: Color.red.opacity(0.92),
                     showsSpinner: false)
            }
            .buttonStyle(.plain)
        case .online, .unknown:
            EmptyView()
        }
    }

    private func pill(text: String, background: Color, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView().tint(.white).scaleEffect(0.8)
            }
            Text(text)
                .font(AgriFont.semibold(13))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(background))
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: status)
    }
}
```

- [ ] **Step 6: Build and run the app**

Run: `xcodebuild build -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED

Then run on the "iPhone 17 Pro" simulator and verify by behavior:
- Sign in → an amber "Connecting…" pill appears briefly, then disappears once `/health` reports the model loaded (silent online state).
- Background the app for >2 min so the container sleeps, then foreground it → the amber pill reappears while it re-warms.
- Turn off networking (simulator → toggle host network or use Airplane Mode on device) and foreground → a red "Server offline — tap to retry" pill appears; tapping it re-pings.
- Open the camera tab while online → no blocking "waking" banner (it stays warm).

- [ ] **Step 7: Run the full test suite**

Run: `xcodebuild test -scheme AgriVision -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: all tests PASS (existing suite + `ServerStatusTests`).

- [ ] **Step 8: Commit**

```bash
git add AgriVision/AgriVisionApp.swift AgriVision/Views/Main/MainTabView.swift
git commit -m "feat(ios): foreground-driven warmup and server status pill"
```

---

## Notes / known limitations

- **`model_loaded:false` is treated as `.offline`** per the approved spec. With model weights baked into the image the model loads during container boot, so `/health` almost always returns `model_loaded:true` once it responds; the false case is a narrow window. If it proves visible in practice, a follow-up could map it to `.connecting` with a single delayed re-check (out of scope here — spec says no retry/polling).
- **No status persistence and no automatic offline retry** beyond the user tapping the red pill or the next foreground/appear trigger — intentional per the spec's YAGNI scope.
- **`MockRecognitionService` is left unchanged** (spec §6 floated a settable `status` on it). The pill is a pure view that takes a `ServerStatus` value directly, so each pill state is exercised by passing the value — the mock never needs a `status` property, and `isReady` is not part of the `RecognitionService` protocol. Adding an unused property would be dead code, so the spec's intent (test every pill state) is met without it.
