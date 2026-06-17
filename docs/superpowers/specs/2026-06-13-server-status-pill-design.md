# Server Status Pill — Design

**Date:** 2026-06-13
**Branch:** ios-recognition
**Status:** Approved, ready for implementation plan

## Problem

The embedder is a scale-to-zero Cloud Run service: it sleeps after ~15 minutes
idle and takes 20–30 s to cold-start. The app's only warmup today runs once at
launch (`AgriVisionApp.swift:28-31`, `await recognition.warmUp()` after
`auth.bootstrap()`), and the only user-facing feedback is a blocking loading
screen on the camera tab (`CameraView.swift:762`, gated on `!recognition.isReady`).

This fails the most common usage pattern: users rarely kill the app — they
background it (return to the home screen) and come back later. When they return,
the launch-time warmup never re-runs, the container has often gone back to sleep,
and the stale `isReady == true` flag means the first identify silently eats a
full cold start. A fresh sign-in (vs. a restored session) also never triggers a
warmup.

## Goal

A seamless experience where the server is warmed on user *activity* rather than
app *launch*, and where status feedback is quiet when healthy and only surfaces
when the user needs to act.

## Why not move the search to the database instead

Considered and rejected for this change. "Identify" is two steps: (1) embed the
query photo into a 2152-d vector via the MiewID model, then (2) cosine-search the
gallery. Step 2 is a trivial DB query (already `db.py:42`, `e.vec <=> $1`), but
step 1 requires the neural network and can only run in the embedder — the query
photo is new every time, so its vector cannot be precomputed. Eliminating the
embedder from identify would require on-device embedding (a CoreML port of
MiewID), which is a separate, much larger project. We keep the current
architecture and make the cold start invisible instead.

## Design

### 1. Status state model

`CloudRunRecognitionService` gains a published status enum; `isReady` becomes
derived from it (preserving the existing camera gate and protocol surface):

```swift
enum ServerStatus { case unknown, connecting, online, offline }
@Published var status: ServerStatus = .unknown
var isReady: Bool { status == .online }
```

`unknown` is the initial state — nothing is shown until the first check runs.

### 2. `warmUp()` drives the states, with a debounce

```swift
private var lastOnlineCheck: Date?

func warmUp() async {
    // Debounce: skip if recently confirmed online (container idle timeout ~15 min).
    if status == .online, let last = lastOnlineCheck,
       Date().timeIntervalSince(last) < 120 { return }
    status = .connecting
    // ...existing /health GET with coldStartTimeout...
    if /* 200 and */ health.modelLoaded {
        status = .online
        lastOnlineCheck = Date()
    } else {
        status = .offline
    }
}
```

The amber → green/red transition falls out of the enum. The existing
`coldStartTimeout` (90 s) and `/health` request are reused unchanged.

### 3. Trigger points

These replace the single launch-time ping:

- **Sign-in success** — fire `warmUp()` when auth transitions to signed-in
  (covers a fresh login, which a restored session-at-launch path does not).
- **App foreground** — `RootView` observes `scenePhase`; on `.active`, fire
  `warmUp()`. This catches the background-and-return case and, as a side effect,
  the ping itself resets the container's idle timer — active users keep it warm.

The debounce (§2) prevents spamming on rapid background/foreground toggles while
still catching a genuinely slept container (>120 s).

### 4. Status pill (global overlay)

A small `ServerStatusPill` rendered once at `RootView` level so it floats over
every tab, top-center below the status bar, non-blocking:

- `.connecting` → amber, "Connecting…", stays up until resolved.
- `.offline` → red, "Server offline — tap to retry"; tap calls `warmUp()`;
  persists until recovery or retry.
- `.online` / `.unknown` → **renders nothing** (silent when healthy).

### 5. Camera screen unchanged

`CameraView` keeps its existing `!isReady` gate as a safety net. With foreground
warmup the container is almost always warm on arrival, so the blocking screen
becomes a rare fallback rather than the primary feedback channel.

### 6. Testing

- `MockRecognitionService` gains a settable `status` to drive previews/tests of
  each pill state.
- Debounce: no re-ping within 120 s of a confirmed-online check; does re-ping
  after the window, and always re-pings when not currently `.online`.
- State transitions: 200 + `model_loaded:true` → `.online`; non-200, timeout, or
  `model_loaded:false` → `.offline`; entry into `warmUp()` → `.connecting`.

## Out of scope (YAGNI)

- Persisting status across launches.
- Retry backoff / offline request queue.
- Cold-vs-warm ("already running" vs "just started") distinction — a single
  `/health` call cannot tell them apart cleanly, and the user does the same thing
  either way.
- Any settings toggle for the behavior.
- On-device (CoreML) embedding — separate future project.
