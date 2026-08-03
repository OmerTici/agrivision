import AVFoundation
import SwiftUI
import UIKit

/// Debounces a noisy on/off detection signal for calmer UI feedback.
/// Must be held for `holdToActivate` before turning on; brief misses up to
/// `graceWhenLost` keep it on.
fileprivate struct StableGate {
    private var active = false
    private var streakSince: Date?
    private var lastHit: Date?

    let holdToActivate: TimeInterval
    let graceWhenLost: TimeInterval

    init(holdToActivate: TimeInterval, graceWhenLost: TimeInterval) {
        self.holdToActivate = holdToActivate
        self.graceWhenLost = graceWhenLost
    }

    mutating func reset() {
        active = false
        streakSince = nil
        lastHit = nil
    }

    mutating func update(hit: Bool, now: Date = Date()) -> Bool {
        if hit {
            lastHit = now
            if streakSince == nil { streakSince = now }
        } else if let last = lastHit, now.timeIntervalSince(last) > graceWhenLost {
            reset()
            return false
        }

        guard streakSince != nil else { return false }

        if !active,
           let since = streakSince,
           now.timeIntervalSince(since) >= holdToActivate {
            active = true
        }
        return active
    }
}

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
        /// Hub mode: cow-gated muzzle scans (with crop) handed back to the
        /// Add-Animal screen instead of being submitted here.
        case collectMuzzles
        /// Hub mode: ungated full-frame snaps (profile / cow body) handed back to
        /// the Add-Animal screen. No cow gate, no muzzle crop — just a shutter.
        case collectFrames
    }

    /// Phase within an enrollment session.
    enum EnrollPhase: Equatable {
        case collectingMuzzles   // gathering the 5-photo burst
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
    /// Set to true (on main) once the enrollment burst is complete (5 crops collected).
    /// The view observes this flag to trigger submitEnrollment and resets it after consuming.
    @Published var readyToSubmit = false
    /// The uncropped parent frame of the highest-confidence muzzle crop in the
    /// current burst — uploaded as the animal's "full" photo so it always shows
    /// the exact frame the on-device pipeline processed (main-thread only).
    private var enrollFullFrame: (confidence: Float, image: UIImage)?
    /// Optional full-frame photos gathered on the Add-Animal hub (profile + cow
    /// body) and submitted alongside the muzzle burst as `full_images`.
    private var extraFullFrames: [UIImage] = []
    /// The uncropped parent frame of EVERY successful muzzle scan (not just the
    /// best). Submitted as `frame_images` — raw dataset material the embedder
    /// team asked to keep; stored server-side under `frame/`, never user-facing.
    private var muzzleSourceFrames: [UIImage] = []
    /// All uncropped parents from a `collectMuzzles` session, returned to the hub.
    var collectedSourceFrames: [UIImage] { muzzleSourceFrames }
    /// Most images a collection session may gather before auto-finishing.
    private var collectTarget = 1
    /// Flipped true (on main) when a collection session reaches its target.
    /// The view observes this to hand the images back and dismiss.
    @Published var collectComplete = false
    /// True during ungated frame collection: the shutter fires on tap with no cow
    /// gate (profile / cow body photos are quality-of-life, not matched).
    @Published private(set) var ungatedCapture = false
    /// The best full frame from a `collectMuzzles` session, returned to the hub.
    var collectedBestFull: UIImage? { enrollFullFrame?.image }
    /// Network/identify error message key or text for the result card.
    @Published var recognitionError: String?

    enum CaptureMode: String, CaseIterable {
        case automatic = "Automatic"
        case manual = "Manual"

        var key: String {
            switch self {
            case .automatic: return "camera.mode.automatic"
            case .manual: return "camera.mode.manual"
            }
        }
    }

    /// Which recognizer the identify camera runs: muzzle matching (default) or
    /// ear-tag OCR. Only offered on the identify tab — collection/enroll
    /// sessions are always muzzle-based.
    enum ScanMode: String, CaseIterable {
        case muzzle
        case earTag

        var key: String {
            switch self {
            case .muzzle: return "camera.scanMode.muzzle"
            case .earTag: return "camera.scanMode.earTag"
            }
        }
    }

    @Published var scanMode: ScanMode = .muzzle
    /// Ear-tag OCR result, set once the same tag is read on consecutive passes
    /// (single misreads never lock). nil while still scanning.
    @Published var detectedTag: String?

    @Published var status: Status = .idle
    @Published var captureMode: CaptureMode = .automatic
    @Published var lastPhoto: UIImage?

    /// True when a stable cow enables capture UI (green brackets / countdown).
    @Published var cowVisible = false
    /// True in manual mode when a stable cow enables the shutter.
    @Published var canManualCapture = false
    /// Set once a photo is captured and a muzzle crop is produced.
    @Published var croppedMuzzle: UIImage?
    /// Drives the on-screen success message.
    @Published var captureSucceeded = false
    /// Shown when capture/analysis fails (no muzzle crop, etc.).
    @Published var captureFailed = false
    /// Localization key for the failure reason; translated by the view.
    @Published var failureMessage = ""
    /// True briefly while the final photo is being processed/cropped.
    @Published var isProcessing = false
    /// Live tuning readout (top detection confidence + size).
    @Published var debugReadout = "Searching…"
    /// Per-model confidences for the captured photo, shown on the result overlay.
    @Published var captureConfidenceText = ""
    /// Seconds remaining on the hold countdown (nil when not counting down).
    @Published var countdown: Int?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "agrivision.camera.session")
    private let videoQueue = DispatchQueue(label: "agrivision.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var isConfigured = false
    /// Back camera input device, kept for zoom control (touched on sessionQueue).
    private var videoDevice: AVCaptureDevice?

    /// Current digital zoom applied to the device. Zooming also feeds the
    /// detector a magnified frame, so a far cow can be zoomed past the area gate.
    @Published private(set) var zoomFactor: CGFloat = 1.0
    /// Cap well below the sensor max — past ~6× the upscaled still is too soft
    /// for a useful muzzle crop.
    static let maxZoom: CGFloat = 6.0

    /// Applies a pinch zoom, clamped to [1, maxZoom] and the device's own limit.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let limit = min(device.activeFormat.videoMaxZoomFactor, Self.maxZoom)
            let clamped = max(1.0, min(factor, limit))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {}
        }
    }

    // Detection / auto-capture state (touched only on videoQueue).
    private let cowDetector = CowDetectorService()
    private let muzzleDetector = MuzzleDetectorService()
    private let earTagReader = EarTagReaderService()
    private var isAnalyzing = false
    private var hasAutoCaptured = false
    /// Mirror of `scanMode` for videoQueue (avoid reading @Published off-main).
    private var isEarTagMode = false
    /// True once a tag has locked; stops OCR until the result card is dismissed.
    private var earTagLocked = false
    /// Throttles the OCR pass — Vision's accurate recognizer is too slow to run
    /// on every camera frame.
    private var lastOCRAt: Date?
    private let ocrInterval: TimeInterval = 0.25
    /// Votes per candidate read this scan session, keyed by serial digits so
    /// full ("TR201755219") and header-missed ("1755219") reads of the SAME
    /// physical tag pool their votes instead of competing (videoQueue only).
    /// Plurality voting: a stable misread can be overtaken by the true tag.
    private var tagVotes: [String: Int] = [:]
    /// The most complete textual form seen per serial key (TR-prefixed beats
    /// bare serial) — what actually gets displayed on lock.
    private var tagBestForm: [String: String] = [:]
    /// The farmer's herd tags — reads that match one lock sooner (videoQueue only).
    private var knownTags: [String] = []
    /// Mirror of `captureMode` for use on `videoQueue` (avoid reading @Published off-main).
    private var isAutomaticMode = true
    /// When the current qualifying streak began.
    private var qualifyingSince: Date?

    /// Smooths live detection flicker before updating UI / countdown.
    private var manualReadyGate = StableGate(holdToActivate: 0.30, graceWhenLost: 1.15)
    private var autoCowGate = StableGate(holdToActivate: 0.30, graceWhenLost: 1.25)
    /// Last time a qualifying cow actually hit (for motion dropout tolerance).
    private var lastCowHit: Date?
    /// How long a started countdown survives missed frames (hand shake / movement).
    private let countdownDropoutGrace: TimeInterval = 1.1

    // MARK: Cow gating (tune these)
    //
    // The live gate uses a stock COCO YOLO11s detector and keys on the whole-animal
    // "cow" box, so the geometry is loose: a close cow can fill the frame and touch
    // the edges. The muzzle is localized separately on the captured still.

    /// How long a qualifying cow must be held steady before auto-capture.
    /// Barn testing (2026-07): swinging heads made a 2.0s hold nearly impossible
    /// to complete; capture timing is better handled by seeing an actual muzzle
    /// than by demanding a long steady cow.
    private let holdDuration: TimeInterval = 0.8
    /// Once the auto hold completes, watch the live frames for an actual muzzle
    /// and fire the still the moment one shows — a swinging head gets caught at
    /// the right pose with a single, well-timed shutter (field feedback: the
    /// 3-still burst read as chaotic free-firing). If no muzzle appears within
    /// this window, fire anyway and let the crop-on-still verdict decide.
    private let muzzleSeekTimeout: TimeInterval = 2.5
    /// Live-preview muzzle confidence that triggers the still.
    private let liveMuzzleThreshold: Float = 0.30
    /// When the current muzzle seek began (touched only on videoQueue).
    private var muzzleSeekSince: Date?

    /// Minimum confidence for the live preview gate. Stock COCO "cow" scores run
    /// ~0.3–0.9 depending on framing. Field scores on real cows sit at 0.90+,
    /// so this rejects background clutter without touching real framings.
    private let cowConfidenceThreshold: Float = 0.55
    /// Floor for cropping a muzzle from the captured still — the muzzle YOLO11n
    /// export's NMS won't emit below 0.25, so this accepts what it detects and
    /// lets a failed crop ask for a retry rather than enrolling a junk box.
    private let muzzleConfidenceThreshold: Float = 0.25
    /// The cow must cover this fraction of the frame by area. Barn testing
    /// (2026-07) showed the old 0.12 floor plus edge/center checks rejected
    /// nearly every real framing — close cows touch the frame edges. The live
    /// gate now trusts the detector; the muzzle crop on the captured still is
    /// the real quality authority. This floor only screens out cows across the
    /// barn — pinch-to-zoom handles those.
    private let minCowAreaFraction: CGFloat = 0.04

    private static let idleReadout = "Point at the cow's head…"

    var showsResultOverlay: Bool { captureSucceeded || captureFailed }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setStatus(.authorized)
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.setStatus(.authorized)
                    self.configureAndRun()
                } else {
                    self.setStatus(.denied)
                }
            }
        default:
            setStatus(.denied)
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Clears the captured result and re-arms auto-capture for another scan.
    func scanAgain() {
        DispatchQueue.main.async {
            self.croppedMuzzle = nil
            self.captureSucceeded = false
            self.captureFailed = false
            self.failureMessage = ""
            self.lastPhoto = nil
            self.cowVisible = false
            self.canManualCapture = false
            self.countdown = nil
            self.debugReadout = Self.idleReadout
            self.captureConfidenceText = ""
        }
        resetLiveDetectionState()
    }

    func dismissResultOverlay() {
        scanAgain()
    }

    func setCaptureMode(_ mode: CaptureMode) {
        DispatchQueue.main.async {
            guard self.captureMode != mode else { return }
            self.captureMode = mode
            self.croppedMuzzle = nil
            self.captureSucceeded = false
            self.captureFailed = false
            self.failureMessage = ""
            self.lastPhoto = nil
            self.cowVisible = false
            self.canManualCapture = false
            self.countdown = nil
            self.isProcessing = false
            self.debugReadout = Self.idleReadout
            self.captureConfidenceText = ""
        }
        videoQueue.async { [weak self] in
            self?.isAutomaticMode = mode == .automatic
            self?.qualifyingSince = nil
            self?.muzzleSeekSince = nil
            self?.hasAutoCaptured = false
        }
    }

    /// Switches the identify camera between muzzle matching and ear-tag OCR.
    /// Hard-resets BOTH pipelines: an auto-capture in flight at switch time
    /// must not surface its result (or popup) under the other mode's UI.
    func setScanMode(_ mode: ScanMode) {
        DispatchQueue.main.async {
            guard self.scanMode != mode else { return }
            self.scanMode = mode
            self.detectedTag = nil
            self.cowVisible = false
            self.countdown = nil
            self.croppedMuzzle = nil
            self.captureSucceeded = false
            self.captureFailed = false
            self.failureMessage = ""
            self.isProcessing = false
            self.identifyResult = nil
            self.recognitionError = nil
            self.canManualCapture = false
            self.debugReadout = mode == .earTag ? "camera.tagHint" : Self.idleReadout
        }
        videoQueue.async { [weak self] in
            self?.isEarTagMode = mode == .earTag
            self?.earTagLocked = false
            self?.tagVotes = [:]
            self?.tagBestForm = [:]
            self?.qualifyingSince = nil
            self?.muzzleSeekSince = nil
            self?.hasAutoCaptured = false
        }
    }

    /// Clears a locked tag result and re-arms ear-tag scanning.
    func resetEarTag() {
        DispatchQueue.main.async {
            self.detectedTag = nil
            self.cowVisible = false
            self.debugReadout = "camera.tagHint"
        }
        videoQueue.async { [weak self] in
            self?.earTagLocked = false
            self?.tagVotes = [:]
            self?.tagBestForm = [:]
        }
    }

    private func resetLiveDetectionState() {
        videoQueue.async { [weak self] in
            self?.qualifyingSince = nil
            self?.hasAutoCaptured = false
            self?.lastCowHit = nil
            self?.muzzleSeekSince = nil
            self?.manualReadyGate.reset()
            self?.autoCowGate.reset()
        }
    }

    private func setStatus(_ newStatus: Status) {
        DispatchQueue.main.async {
            self.status = newStatus
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoDevice = device
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }

                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }

                self.session.commitConfiguration()
                self.isConfigured = true
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    /// Runs the full detection pipeline on an image picked from the photo library.
    /// Lets you test the real models on clean files — no camera, no screen moiré.
    func analyzeImported(_ image: UIImage) {
        DispatchQueue.main.async {
            self.lastPhoto = image
            self.isProcessing = true
            self.captureSucceeded = false
            self.captureFailed = false
        }
        processCapturedPhoto(image)
    }

    func capturePhoto() {
        // Ear-tag mode has no shutter; a stray trigger racing a mode switch
        // must not fire the muzzle pipeline.
        if scanMode == .earTag { return }
        // Ungated frame collection ignores the cow gate — the shutter always fires.
        if captureMode == .manual && !canManualCapture && !ungatedCapture { return }
        if isContacting { return }

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
                }
                self.processCapturedPhoto(image)
            }
            self.captureDelegate = delegate
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    /// Crops the muzzle from the captured still. The live cow gate already decided
    /// whether to fire the shutter; here the muzzle detector is the sole authority —
    /// no muzzle box, no crop, ask for a retry. This also rejects non-cow stills
    /// (imported test images, mis-fires) because they have no muzzle to find.
    private func processCapturedPhoto(_ image: UIImage?) {
        videoQueue.async { [weak self] in
            guard let self else { return }

            guard let cgImage = image?.normalizedCGImage() else {
                self.finishFailure("camera.fail.read", confidence: "")
                return
            }

            // Hub frame collection (profile / cow body): the live cow gate already
            // vouched for the frame, so accept the full image with no muzzle crop.
            if case .collectFrames = self.purpose {
                self.finishFrameSuccess(frame: image)
                return
            }

            let detections = self.muzzleDetector.detections(in: cgImage, orientation: .up)
            let best = detections.max(by: { $0.confidence < $1.confidence })
            let muzzleConf = best?.confidence ?? 0
            let confText = String(format: "Muzzle %.2f", muzzleConf)

            guard let best,
                  muzzleConf >= self.muzzleConfidenceThreshold,
                  let crop = self.muzzleDetector.cropMuzzle(from: cgImage, boundingBox: best.boundingBox)
            else {
                self.finishFailure("camera.fail.crop", confidence: confText)
                return
            }

            self.finishSuccess(crop: crop, fullFrame: image, confidence: best.confidence, confidenceText: confText)
        }
    }


    private func finishSuccess(crop: UIImage, fullFrame: UIImage?, confidence: Float, confidenceText: String) {
        DispatchQueue.main.async {
            // A capture that resolves after the user switched to ear-tag mode
            // would surface a muzzle result under the tag UI — drop it.
            if self.scanMode == .earTag, case .identify = self.purpose {
                self.isProcessing = false
                return
            }
            self.croppedMuzzle = crop
            self.captureConfidenceText = confidenceText
            self.isProcessing = false
            self.captureFailed = false
            self.failureMessage = ""

            switch self.purpose {
            case .identify:
                self.captureSucceeded = true
            case .enroll:
                self.collectedCrops.append(crop)
                if let fullFrame {
                    self.muzzleSourceFrames.append(fullFrame)
                    if confidence > (self.enrollFullFrame?.confidence ?? 0) {
                        self.enrollFullFrame = (confidence, fullFrame)
                    }
                }
                if self.collectedCrops.count >= Self.enrollTarget {
                    // Burst complete — stay paused; the view triggers submission.
                    self.readyToSubmit = true
                } else {
                    // Brief beat before re-arming so the farmer sees the count
                    // tick and scans fire at a readable rhythm, not machine-gun.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        self.rearmForNextEnrollCrop()
                    }
                }
            case .collectMuzzles:
                self.collectedCrops.append(crop)
                if let fullFrame {
                    self.muzzleSourceFrames.append(fullFrame)
                    if confidence > (self.enrollFullFrame?.confidence ?? 0) {
                        self.enrollFullFrame = (confidence, fullFrame)
                    }
                }
                if self.collectedCrops.count >= self.collectTarget {
                    self.collectComplete = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        self.rearmForNextEnrollCrop()
                    }
                }
            case .collectFrames:
                // Frame collection runs through finishFrameSuccess, not here.
                break
            }
        }
    }

    /// Accepts a full frame during a `collectFrames` hub session. Appends it to
    /// `collectedCrops` (reused as the generic image buffer) and either finishes
    /// the session at the target or re-arms for the next shot.
    private func finishFrameSuccess(frame: UIImage?) {
        DispatchQueue.main.async {
            guard let frame else {
                self.finishFailure("camera.fail.read", confidence: "")
                return
            }
            self.croppedMuzzle = nil
            self.isProcessing = false
            self.captureFailed = false
            self.failureMessage = ""
            self.collectedCrops.append(frame)
            if self.collectedCrops.count >= self.collectTarget {
                self.collectComplete = true
            } else {
                self.rearmForNextEnrollCrop()
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
        cowVisible = false
        canManualCapture = false
        debugReadout = Self.idleReadout
        captureConfidenceText = ""
        resetLiveDetectionState()
    }

    private func finishFailure(_ messageKey: String, confidence: String) {
        DispatchQueue.main.async {
            // Same stale-capture guard as finishSuccess: no muzzle failure
            // cards under the ear-tag UI after a mode switch.
            if self.scanMode == .earTag, case .identify = self.purpose {
                self.isProcessing = false
                return
            }
            self.croppedMuzzle = nil
            self.captureConfidenceText = confidence
            self.isProcessing = false
            self.captureSucceeded = false
            self.failureMessage = messageKey
            self.captureFailed = true
            self.canManualCapture = false
        }
        resetLiveDetectionState()
    }

    // MARK: Enrollment / identify orchestration

    /// Switches the model into enrollment mode for a specific animal.
    ///
    /// - Parameters:
    ///   - seedCrops: muzzle crops already gathered (e.g. the one carried in from
    ///     the "not recognized" screen). These count toward `enrollTarget`, so a
    ///     single seed means the burst only needs four more.
    ///   - seedFullFrame: the full frame behind the seed crop, used as a fallback
    ///     "full" photo if no later burst frame scores higher.
    ///   - extraFullFrames: optional profile + cow body photos gathered on the
    ///     hub; submitted as `full_images` alongside the muzzle burst.
    func beginEnrollment(
        animalID: String,
        seedCrops: [UIImage] = [],
        seedFullFrame: UIImage? = nil,
        extraFullFrames: [UIImage] = []
    ) {
        DispatchQueue.main.async {
            self.purpose = .enroll(animalID: animalID)
            self.ungatedCapture = false
            self.collectedCrops = seedCrops
            self.enrollFullFrame = seedFullFrame.map { (0, $0) }
            self.muzzleSourceFrames = seedFullFrame.map { [$0] } ?? []
            self.extraFullFrames = extraFullFrames
            self.enrollPhase = .collectingMuzzles
            self.identifyResult = nil
            self.recognitionError = nil
            self.captureSucceeded = false
            self.captureFailed = false
            // A seed may already satisfy the target (shouldn't normally, but stay safe).
            if self.collectedCrops.count >= Self.enrollTarget {
                self.readyToSubmit = true
            }
        }
        resetLiveDetectionState()
        DispatchQueue.main.async { self.scanAgain() }
    }

    /// Switches the model into hub muzzle-collection mode: cow-gated muzzle scans
    /// (with crop) that are handed back to the Add-Animal hub. Gathers up to `max`.
    func beginMuzzleCollection(max: Int) {
        DispatchQueue.main.async {
            self.purpose = .collectMuzzles
            self.ungatedCapture = false
            self.collectTarget = Swift.max(1, max)
            self.collectedCrops = []
            self.enrollFullFrame = nil
            self.muzzleSourceFrames = []
            self.extraFullFrames = []
            self.collectComplete = false
            self.identifyResult = nil
            self.recognitionError = nil
            self.captureSucceeded = false
            self.captureFailed = false
        }
        resetLiveDetectionState()
        DispatchQueue.main.async { self.scanAgain() }
    }

    /// Switches the model into hub frame-collection mode (profile / cow body).
    /// Ungated: forces manual mode and fires the shutter on tap with no cow gate.
    /// Gathers up to `max` full frames, then sets `collectComplete`.
    func beginFrameCollection(max: Int) {
        DispatchQueue.main.async {
            self.purpose = .collectFrames
            self.ungatedCapture = true
            self.captureMode = .manual
            self.collectTarget = Swift.max(1, max)
            self.collectedCrops = []
            self.enrollFullFrame = nil
            self.extraFullFrames = []
            self.collectComplete = false
            self.identifyResult = nil
            self.recognitionError = nil
            self.captureSucceeded = false
            self.captureFailed = false
        }
        resetLiveDetectionState()
        DispatchQueue.main.async { self.scanAgain() }
    }

    /// Ends a `collectFrames` session early (the user tapped Done) with whatever
    /// frames have been gathered so far.
    func finalizeFrameCollection() {
        DispatchQueue.main.async { self.collectComplete = true }
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
        // The best burst frame plus any hub photos (profile + cow body) all ride
        // along as `full_images`.
        var fullJpegs: [Data] = []
        if let best = enrollFullFrame.flatMap({ ImageEncoding.fullBodyJPEG($0.image) }) {
            fullJpegs.append(best)
        }
        fullJpegs.append(contentsOf: extraFullFrames.compactMap { ImageEncoding.fullBodyJPEG($0) })
        // Every scan's uncropped parent frame rides along as raw dataset material.
        let frameJpegs = muzzleSourceFrames.compactMap { ImageEncoding.fullBodyJPEG($0) }
        guard muzzleJpegs.count == collectedCrops.count, !muzzleJpegs.isEmpty else {
            recognitionError = Self.localizedRecognitionMessage(for: RecognitionError.encoding)
            enrollPhase = .failed
            return
        }
        do {
            _ = try await service.enroll(animalID: animalID,
                                         muzzleJpegs: muzzleJpegs,
                                         fullJpegs: fullJpegs,
                                         frameJpegs: frameJpegs)
            enrollPhase = .done
        } catch {
            recognitionError = Self.localizedRecognitionMessage(for: error)
            enrollPhase = .failed
        }
    }

    /// Maps a thrown recognition error to a localized, user-facing message at the
    /// UI boundary so `RecognitionError` (Services layer) stays free of LanguageManager.
    static func localizedRecognitionMessage(for error: Error) -> String {
        let lang = LanguageManager.shared
        switch error {
        case RecognitionError.notAuthenticated:
            return lang.t("recognition.error.notAuthenticated")
        case let RecognitionError.http(status, _):
            return lang.t("recognition.error.http", status)
        case RecognitionError.transport:
            return lang.t("recognition.error.network")
        case RecognitionError.encoding:
            return lang.t("recognition.error.encoding")
        case RecognitionError.decoding:
            return lang.t("recognition.error.decoding")
        default:
            return error.localizedDescription
        }
    }

    /// Runs identify on the current crop and stores the result.
    @MainActor
    func runIdentify(using service: RecognitionService) async {
        guard let crop = croppedMuzzle, let jpeg = ImageEncoding.muzzleJPEG(crop) else { return }
        // Send the uncropped frame too, when available, so the embedder team
        // gets the raw image alongside the crop. Never blocks matching.
        let frameJpeg = lastPhoto.flatMap { ImageEncoding.fullBodyJPEG($0) }
        isContacting = true
        recognitionError = nil
        defer { isContacting = false }
        do {
            identifyResult = try await service.identify(jpegData: jpeg, frameData: frameJpeg)
        } catch {
            recognitionError = Self.localizedRecognitionMessage(for: error)
        }
    }

    /// Releases captured images after a completed enrollment so the model
    /// doesn't hold full-res UIImages once the session is over.
    func releaseCapturedImages() {
        collectedCrops = []
        enrollFullFrame = nil
        muzzleSourceFrames = []
        extraFullFrames = []
        lastPhoto = nil
    }

    /// Clears identify/enroll state and re-arms for another scan.
    func resetRecognition() {
        DispatchQueue.main.async {
            self.identifyResult = nil
            self.recognitionError = nil
            self.collectedCrops = []
            self.enrollFullFrame = nil
            self.muzzleSourceFrames = []
            self.enrollPhase = .collectingMuzzles
        }
        scanAgain()
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !hasAutoCaptured, !isAnalyzing else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        if isEarTagMode {
            processEarTagFrame(pixelBuffer)
        } else if isAutomaticMode {
            processAutomaticFrame(pixelBuffer)
        } else {
            processManualFrame(pixelBuffer)
        }
    }

    /// Ear-tag mode: OCR the live frame (throttled) and lock by plurality vote.
    /// A read matching a herd tag locks at 2 sightings; an unknown number needs
    /// 3 AND strictly more votes than any rival, so a stable misread can still
    /// be overtaken by the true tag as framing improves.
    private func processEarTagFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !earTagLocked else { return }
        let now = Date()
        if let last = lastOCRAt, now.timeIntervalSince(last) < ocrInterval { return }
        lastOCRAt = now

        guard let tag = earTagReader.readTag(in: pixelBuffer, orientation: .up) else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanMode == .earTag else { return }
                self.cowVisible = false
                self.debugReadout = "camera.tagHint"
            }
            return
        }

        let key = EarTagReaderService.serialKey(tag)
        tagVotes[key, default: 0] += 1
        if tag.count > (tagBestForm[key]?.count ?? 0) {
            tagBestForm[key] = tag
        }
        let display = tagBestForm[key] ?? tag

        let votes = tagVotes[key] ?? 0
        let rivalBest = tagVotes.lazy.filter { $0.key != key }.map(\.value).max() ?? 0
        let matchesHerd = knownTags.contains { EarTagReaderService.matches(stored: $0, read: display) }
        let needed = matchesHerd ? 2 : 3
        let locked = votes >= needed && votes > rivalBest
        if locked { earTagLocked = true }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanMode == .earTag else { return }
            self.cowVisible = true
            self.debugReadout = display
            if locked { self.detectedTag = display }
        }
    }

    /// Herd tags used to bias ear-tag locking toward numbers that actually
    /// exist in this herd. Call whenever the herd list changes.
    func setKnownTags(_ tags: [String]) {
        videoQueue.async { [weak self] in
            self?.knownTags = tags
        }
    }

    private func processAutomaticFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()

        let cowDetections = cowDetector.detections(in: pixelBuffer, orientation: .up)
        let cowBest = cowDetections.max(by: { $0.confidence < $1.confidence })
        let cowOk = cowBest.map(qualifiesCowLive) ?? false
        if cowOk { lastCowHit = now }

        let cowStable = autoCowGate.update(hit: cowOk, now: now)

        if cowStable, qualifyingSince == nil {
            qualifyingSince = now
        }

        if qualifyingSince != nil {
            let recentCow = lastCowHit.map { now.timeIntervalSince($0) <= countdownDropoutGrace } ?? false
            if !recentCow {
                qualifyingSince = nil
                lastCowHit = nil
                muzzleSeekSince = nil
            }
        }

        let counting = qualifyingSince != nil
        let remaining = qualifyingSince.map { holdDuration - now.timeIntervalSince($0) } ?? holdDuration
        let seeking = counting && remaining <= 0
        let countdownValue: Int? = counting && remaining > 0 ? max(1, Int(ceil(remaining))) : nil
        let showGreen = cowStable || counting

        let readout: String
        if seeking {
            readout = "camera.seekMuzzle"
        } else if counting, let cowBest {
            let box = cowBest.boundingBox
            readout = String(
                format: "Cow conf %.2f · size %.0f%%×%.0f%% · holding…",
                cowBest.confidence,
                box.width * 100,
                box.height * 100
            )
        } else if cowStable, let cowBest {
            let box = cowBest.boundingBox
            readout = String(
                format: "Cow conf %.2f · size %.0f%%×%.0f%% · ready",
                cowBest.confidence,
                box.width * 100,
                box.height * 100
            )
        } else if cowOk, let cowBest {
            readout = String(format: "Cow conf %.2f · settling…", cowBest.confidence)
        } else if let cowBest {
            // Detection present but below the gate or failing geometry — surface the
            // raw score so the threshold can be tuned against real device numbers.
            let box = cowBest.boundingBox
            readout = String(
                format: "Cow conf %.2f · size %.0f%%×%.0f%% · low",
                cowBest.confidence,
                box.width * 100,
                box.height * 100
            )
        } else {
            readout = Self.idleReadout
        }

        DispatchQueue.main.async { [weak self] in
            self?.cowVisible = showGreen
            self?.debugReadout = readout
            self?.countdown = countdownValue
        }

        if seeking {
            // Hold complete — don't fire blind. Watch the live feed for an actual
            // muzzle so the still catches the head facing the camera; give up and
            // fire anyway after the seek window so a stubborn pose still captures.
            if muzzleSeekSince == nil { muzzleSeekSince = now }
            let liveMuzzle = muzzleDetector.detections(in: pixelBuffer, orientation: .up)
                .map(\.confidence).max() ?? 0
            let seekExpired = now.timeIntervalSince(muzzleSeekSince ?? now) >= muzzleSeekTimeout
            if liveMuzzle >= liveMuzzleThreshold || seekExpired {
                hasAutoCaptured = true
                DispatchQueue.main.async { [weak self] in
                    self?.countdown = nil
                    self?.capturePhoto()
                }
            }
        }
    }

    private func processManualFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()

        let cowDetections = cowDetector.detections(in: pixelBuffer, orientation: .up)
        let cowBest = cowDetections.max(by: { $0.confidence < $1.confidence })
        let cowOk = cowBest.map(qualifiesCowLive) ?? false
        let ready = manualReadyGate.update(hit: cowOk, now: now)

        let readout: String
        if ready, let cowBest {
            readout = String(format: "Cow conf %.2f · ready", cowBest.confidence)
        } else if cowOk, let cowBest {
            readout = String(format: "Cow conf %.2f · settling…", cowBest.confidence)
        } else if let cowBest {
            readout = String(format: "Cow conf %.2f · ignored", cowBest.confidence)
        } else {
            readout = Self.idleReadout
        }

        DispatchQueue.main.async { [weak self] in
            self?.canManualCapture = ready
            self?.debugReadout = readout
        }
    }

    private func qualifiesCowLive(_ detection: CowDetection) -> Bool {
        guard detection.confidence >= cowConfidenceThreshold else { return false }
        let box = detection.boundingBox
        return box.width * box.height >= minCowAreaFraction
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        completion(image)
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

/// Configures CameraScreen to gather images for the Add-Animal hub and hand them
/// back, instead of identifying/enrolling.
struct CameraCollectionRequest: Equatable {
    enum Kind { case muzzle, frame }
    /// `.muzzle` = cow-gated scans with a muzzle crop; `.frame` = ungated snaps.
    let kind: Kind
    /// Most images to gather before the session auto-finishes.
    let max: Int
    /// Localization key for the on-screen counter label (e.g. "camera.collect.cow").
    let titleKey: String
}

struct CameraScreen: View {
    var onClose: () -> Void = {}
    /// Called after a successful enrollment (`.done` state). Fires before `onClose`.
    var onEnrollSuccess: () -> Void = {}
    /// When set, the camera runs an enrollment session for this animal.
    var enrollAnimalID: String? = nil
    /// Muzzle crops to seed the enrollment burst with (e.g. the one carried in
    /// from the "not recognized" screen). Counts toward the 5 required scans.
    var enrollSeedCrops: [UIImage] = []
    /// Full frame behind the seed crop, used as a fallback "full" photo.
    var enrollSeedFullFrame: UIImage? = nil
    /// Optional profile + cow body photos gathered on the hub, submitted as
    /// `full_images` with the muzzle burst.
    var enrollExtraFullFrames: [UIImage] = []
    /// When set, the camera gathers images (muzzle scans or ungated frames) and
    /// returns them instead of identifying or enrolling.
    var collection: CameraCollectionRequest? = nil
    /// Delivers the gathered images (and best full frame, for muzzle collection)
    /// when a collection session finishes.
    var onCollected: (_ images: [UIImage], _ bestFull: UIImage?, _ sourceFrames: [UIImage]) -> Void = { _, _, _ in }
    /// Called when an unknown identify result's "Enroll" button is tapped. Passes
    /// the just-captured muzzle crop and its full frame so enrollment can reuse them.
    var onRequestEnroll: (_ muzzleCrop: UIImage?, _ fullFrame: UIImage?) -> Void = { _, _ in }

    @EnvironmentObject private var recognition: CloudRunRecognitionService
    @EnvironmentObject private var store: HerdStore
    @StateObject private var model = CameraModel()
    @ObservedObject private var lang = LanguageManager.shared
    @State private var flash = false
    @State private var showHelp = false
    @State private var showResult = false
    /// Zoom factor at the start of the current pinch; the gesture scales from here.
    @State private var zoomAnchor: CGFloat = 1.0

    /// Yellow-orange used for the "unrecognized animal" prompt.
    private static let unknownAmber = Color(red: 0.95, green: 0.62, blue: 0.18)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.status {
            case .authorized:
                CameraPreviewView(session: model.session)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                model.setZoom(zoomAnchor * value)
                            }
                            .onEnded { value in
                                zoomAnchor = max(1.0, min(zoomAnchor * value, CameraModel.maxZoom))
                            }
                    )
            case .denied:
                deniedView
            case .idle:
                ProgressView()
                    .tint(AgriColors.white)
            }

            if model.status == .authorized && !model.showsResultOverlay {
                CameraScanFrame(
                    bracketColor: scanBracketColor,
                    hint: scanHint
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.35), value: scanBracketColor)
                .animation(.easeInOut(duration: 0.2), value: model.countdown)

                if model.captureMode == .automatic, let countdown = model.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 78, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                        .transition(.scale.combined(with: .opacity))
                        .id(countdown)
                }

                if model.zoomFactor > 1.01 {
                    VStack {
                        Spacer()
                        Text(String(format: "%.1f×", model.zoomFactor))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .padding(.bottom, 158)
                    }
                    .allowsHitTesting(false)
                }

                if !model.ungatedCapture,
                   model.captureMode == .automatic || model.captureMode == .manual || model.isProcessing {
                    VStack {
                        Spacer()
                        Text(model.isProcessing ? lang.t("camera.analyzing") : lang.t(model.debugReadout))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .padding(.bottom, 120)
                    }
                    .allowsHitTesting(false)
                }
            }

            if flash {
                Color.white.ignoresSafeArea()
            }

            overlayControls

            if model.showsResultOverlay {
                resultOverlay
            }

            if let req = collection {
                collectionOverlay(req)
            }

            if collection == nil, enrollAnimalID != nil {
                enrollmentOverlay
            }

            if collection == nil, enrollAnimalID == nil,
               model.identifyResult != nil || model.recognitionError != nil {
                identifyOverlay
            }

            if collection == nil, enrollAnimalID == nil,
               model.scanMode == .earTag, let tag = model.detectedTag {
                earTagOverlay(tag: tag)
            }

            if !recognition.isReady {
                wakingBanner
            }
        }
        .onAppear {
            model.start()
            model.setKnownTags(store.animals.map(\.tag))
            if let req = collection {
                switch req.kind {
                case .muzzle: model.beginMuzzleCollection(max: req.max)
                case .frame: model.beginFrameCollection(max: req.max)
                }
            } else if let id = enrollAnimalID {
                model.beginEnrollment(animalID: id,
                                      seedCrops: enrollSeedCrops,
                                      seedFullFrame: enrollSeedFullFrame,
                                      extraFullFrames: enrollExtraFullFrames)
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.collectComplete) { _, done in
            guard done else { return }
            model.collectComplete = false
            onCollected(model.collectedCrops, model.collectedBestFull, model.collectedSourceFrames)
            onClose()
        }
        .onChange(of: model.captureSucceeded) { _, succeeded in
            guard succeeded else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            // Identify mode: as soon as a crop is captured, ask the server.
            if collection == nil, enrollAnimalID == nil {
                Task { await model.runIdentify(using: recognition) }
            }
        }
        .onChange(of: model.captureFailed) { _, failed in
            if failed {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
        .onChange(of: model.detectedTag) { _, tag in
            guard tag != nil else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        .onChange(of: store.animals.map(\.tag)) { _, tags in
            model.setKnownTags(tags)
        }
        .onChange(of: model.readyToSubmit) { _, ready in
            guard ready else { return }
            // Consume the flag immediately so this fires exactly once per burst.
            model.readyToSubmit = false
            Task { await model.submitEnrollment(using: recognition) }
        }
        .sheet(isPresented: $showHelp) {
            MuzzleHelpSheet()
        }
        .sheet(isPresented: $showResult) {
            MuzzleResultSheet(cropped: model.croppedMuzzle, full: model.lastPhoto)
        }
    }

    private var scanBracketColor: Color {
        if model.scanMode == .earTag {
            return model.cowVisible ? AgriColors.successGreen : .white
        }
        switch model.captureMode {
        case .automatic:
            return model.cowVisible ? AgriColors.successGreen : .white
        case .manual:
            return model.canManualCapture ? AgriColors.successGreen : .white
        }
    }

    private var scanHint: String {
        if model.scanMode == .earTag {
            return lang.t("camera.tagHint")
        }
        switch model.captureMode {
        case .automatic:
            return lang.t(model.cowVisible ? "camera.hint.hold" : "camera.hint.point")
        case .manual:
            return lang.t(model.canManualCapture ? "camera.hint.tap" : "camera.hint.point")
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button {
                    showHelp = true
                } label: {
                    Text(lang.t("camera.help"))
                        .font(AgriFont.semibold(15))
                        .foregroundStyle(AgriColors.white)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                // Camera-method menu (identify tab only): Default = muzzle
                // matching, or ear-tag OCR.
                if collection == nil, enrollAnimalID == nil {
                    Menu {
                        ForEach(CameraModel.ScanMode.allCases, id: \.self) { mode in
                            Button {
                                model.setScanMode(mode)
                            } label: {
                                if model.scanMode == mode {
                                    Label(lang.t(mode.key), systemImage: "checkmark")
                                } else {
                                    Text(lang.t(mode.key))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AgriColors.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            // Whole circle (plus a little slop) is tappable —
                            // not just the glyph's drawn pixels.
                            .contentShape(Circle().inset(by: -8))
                    }
                    .padding(.trailing, 10)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AgriColors.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // No mode toggle during ungated frame collection — there's no cow gate,
            // so "Automatic" has nothing to trigger on. Ear-tag OCR has no shutter
            // either, so the toggle only applies to muzzle scanning.
            if model.status == .authorized && !model.showsResultOverlay && !model.ungatedCapture
                && model.scanMode == .muzzle {
                captureModePicker
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
            }

            Spacer()

            if model.status == .authorized && !model.showsResultOverlay
                && model.captureMode == .manual && model.scanMode == .muzzle {
                Button(action: capture) {
                    ZStack {
                        Circle()
                            .stroke(AgriColors.white, lineWidth: 5)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(AgriColors.white)
                            .frame(width: 62, height: 62)
                        if model.isProcessing {
                            ProgressView()
                                .tint(AgriColors.purple)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isProcessing || (!model.canManualCapture && !model.ungatedCapture) || model.isContacting)
                .opacity((model.canManualCapture || model.ungatedCapture) && !model.isProcessing && !model.isContacting ? 1 : 0.35)
                .padding(.bottom, 36)
            }
        }
    }

    /// The herd animal whose tag matches an OCR read, if any. Exact normalized
    /// match, or suffix match for serial-only reads where OCR missed the small
    /// "TR xx" header line.
    private func animalForTag(_ tag: String) -> Animal? {
        store.animals.first { EarTagReaderService.matches(stored: $0.tag, read: tag) }
    }

    /// "TR12345678" → "TR 12345678" for display.
    private func displayTag(_ tag: String) -> String {
        tag.hasPrefix("TR") ? "TR " + tag.dropFirst(2) : tag
    }

    /// Result card for a locked ear-tag read: the matched animal, or a
    /// not-registered notice showing exactly what was read.
    private func earTagOverlay(tag: String) -> some View {
        let animal = animalForTag(tag)
        return VStack {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: animal != nil ? "checkmark.seal.fill" : "questionmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(animal != nil ? AgriColors.successGreen : Self.unknownAmber)

                Text(animal?.name ?? lang.t("tag.notFound.title"))
                    .font(AgriFont.bold(22))
                    .foregroundStyle(AgriColors.purpleDark)
                    .multilineTextAlignment(.center)

                // A herd match shows the stored tag (full, farmer-entered form)
                // rather than the possibly header-less OCR read.
                Text(animal.map { displayTag($0.tag) } ?? displayTag(tag))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgriColors.purpleDark.opacity(0.75))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(Capsule().fill(AgriColors.purpleDark.opacity(0.06)))

                if animal == nil {
                    Text(lang.t("tag.notFound.msg"))
                        .font(AgriFont.regular(15))
                        .foregroundStyle(AgriColors.purpleDark.opacity(0.85))
                        .multilineTextAlignment(.center)
                }

                Button {
                    model.resetEarTag()
                } label: {
                    Text(lang.t("camera.scanAgain"))
                        .font(AgriFont.semibold(17))
                        .foregroundStyle(AgriColors.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AgriColors.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AgriColors.white)
            )
            .padding(.horizontal, 28)

            Spacer()
        }
        .background(Color.black.opacity(0.35).ignoresSafeArea())
        .transition(.opacity)
    }

    private var captureModePicker: some View {
        HStack(spacing: 0) {
            ForEach(CameraModel.CaptureMode.allCases, id: \.self) { mode in
                Button {
                    model.setCaptureMode(mode)
                } label: {
                    Text(lang.t(mode.key))
                        .font(AgriFont.semibold(14))
                        .foregroundStyle(
                            model.captureMode == mode ? AgriColors.purpleDark : AgriColors.white
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            model.captureMode == mode
                                ? AgriColors.white
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private var resultOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button {
                        model.dismissResultOverlay()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(AgriColors.purpleDark.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: model.captureSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(model.captureSucceeded ? AgriColors.successGreen : .red)

                Text(lang.t(model.captureSucceeded ? "camera.success.title" : "camera.failed.title"))
                    .font(AgriFont.bold(22))
                    .foregroundStyle(AgriColors.purpleDark)

                Text(lang.t(model.captureSucceeded ? "camera.success.msg" : model.failureMessage))
                    .font(AgriFont.regular(15))
                    .foregroundStyle(AgriColors.purpleDark.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if !model.captureConfidenceText.isEmpty {
                    Text(model.captureConfidenceText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(AgriColors.purpleDark.opacity(0.7))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            Capsule().fill(AgriColors.purpleDark.opacity(0.06))
                        )
                }

                if model.isContacting {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(AgriColors.purple)
                        Text(lang.t("camera.searching"))
                            .font(AgriFont.semibold(14))
                            .foregroundStyle(AgriColors.purpleDark.opacity(0.85))
                    }
                    .padding(.vertical, 4)
                }

                if let cropped = model.croppedMuzzle {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if let full = model.lastPhoto, model.captureFailed {
                    Image(uiImage: full)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(spacing: 10) {
                    if model.captureSucceeded {
                        Button {
                            showResult = true
                        } label: {
                            Text(lang.t("camera.viewResult"))
                                .font(AgriFont.semibold(17))
                                .foregroundStyle(AgriColors.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(AgriColors.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        model.scanAgain()
                    } label: {
                        Text(lang.t("camera.scanAgain"))
                            .font(AgriFont.semibold(16))
                            .foregroundStyle(AgriColors.purple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AgriColors.purple.opacity(0.4), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AgriColors.appBackground)
            )
            .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .transition(.opacity)
    }

    // MARK: Enrollment overlay

    @ViewBuilder
    private var enrollmentOverlay: some View {
        switch model.enrollPhase {
        case .collectingMuzzles:
            VStack {
                Spacer()
                Text(lang.t("camera.enroll.progress", model.collectedCrops.count, CameraModel.enrollTarget))
                    .font(AgriFont.semibold(16))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(Capsule().fill(AgriColors.purple.opacity(0.85)))
                    .padding(.bottom, 160)
            }
            .allowsHitTesting(false)

        case .submitting:
            recognitionScrim {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(lang.t("camera.enroll.submitting"))
                        .font(AgriFont.semibold(16)).foregroundStyle(.white)
                }
            }

        case .done:
            recognitionScrim {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54)).foregroundStyle(AgriColors.successGreen)
                    Text(lang.t("camera.enroll.success"))
                        .font(AgriFont.bold(20)).foregroundStyle(.white)
                    Button {
                        model.releaseCapturedImages()
                        onEnrollSuccess()
                        onClose()
                    } label: {
                        Text(lang.t("camera.done"))
                            .font(AgriFont.semibold(16)).foregroundStyle(AgriColors.purple)
                            .padding(.vertical, 12).padding(.horizontal, 40)
                            .background(AgriColors.white)
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
                        .font(AgriFont.bold(20)).foregroundStyle(.white)
                    if let err = model.recognitionError {
                        Text(err).font(AgriFont.regular(13)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    Button {
                        Task { await model.submitEnrollment(using: recognition) }
                    } label: {
                        Text(lang.t("camera.enroll.retry"))
                            .font(AgriFont.semibold(16)).foregroundStyle(AgriColors.purple)
                            .padding(.vertical, 12).padding(.horizontal, 40)
                            .background(AgriColors.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Collection overlay (Add-Animal hub)

    @ViewBuilder
    private func collectionOverlay(_ req: CameraCollectionRequest) -> some View {
        VStack {
            Text("\(lang.t(req.titleKey))  \(model.collectedCrops.count)/\(req.max)")
                .font(AgriFont.semibold(15))
                .foregroundStyle(.white)
                .padding(.vertical, 8).padding(.horizontal, 16)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.top, 64)

            Spacer()

            // Frame collection (profile / cow body) is user-ended; muzzle scans
            // auto-finish at the target, so no Done button there.
            if req.kind == .frame {
                HStack {
                    Spacer()
                    Button { model.finalizeFrameCollection() } label: {
                        Text(lang.t("camera.collect.done"))
                            .font(AgriFont.semibold(16))
                            .foregroundStyle(model.collectedCrops.isEmpty ? .white.opacity(0.6) : AgriColors.purple)
                            .padding(.vertical, 12).padding(.horizontal, 28)
                            .background(model.collectedCrops.isEmpty ? Color.black.opacity(0.45) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.collectedCrops.isEmpty)
                    .padding(.trailing, 20)
                    .padding(.bottom, 40)
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
                            .font(.system(size: 54)).foregroundStyle(AgriColors.successGreen)
                        Text(result.name ?? lang.t("camera.identify.identified"))
                            .font(AgriFont.bold(22)).foregroundStyle(AgriColors.purpleDark)
                        Text(lang.t("camera.identify.score", result.score * 100))
                            .font(AgriFont.regular(15)).foregroundStyle(AgriColors.tabInactive)
                        secondaryButton(lang.t("camera.scanAgain")) { model.resetRecognition() }
                    } else {
                        ZStack {
                            Circle()
                                .fill(Self.unknownAmber.opacity(0.16))
                                .frame(width: 92, height: 92)
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(Self.unknownAmber)
                        }
                        Text(lang.t("camera.identify.unknown"))
                            .font(AgriFont.bold(21)).foregroundStyle(AgriColors.purpleDark)
                        Text(lang.t("camera.identify.unknownPrompt"))
                            .font(AgriFont.regular(15)).foregroundStyle(AgriColors.tabInactive)
                            .multilineTextAlignment(.center)
                        primaryButton(lang.t("camera.identify.enroll")) {
                            onRequestEnroll(model.croppedMuzzle, model.lastPhoto)
                        }
                        secondaryButton(lang.t("camera.scanAgain")) { model.resetRecognition() }
                    }
                } else if model.recognitionError != nil {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 46)).foregroundStyle(AgriColors.tabInactive)
                    Text(lang.t("camera.identify.offline"))
                        .font(AgriFont.semibold(16)).foregroundStyle(AgriColors.purpleDark)
                    secondaryButton(lang.t("camera.scanAgain")) { model.resetRecognition() }
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AgriColors.white)
            )
            .padding(.horizontal, 40)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AgriFont.semibold(16)).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AgriColors.purple)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AgriFont.semibold(16)).foregroundStyle(AgriColors.purple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AgriColors.purple.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var wakingBanner: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().tint(.white).scaleEffect(0.8)
                Text(lang.t("camera.identify.waking"))
                    .font(AgriFont.semibold(13)).foregroundStyle(.white)
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

    private func capture() {
        model.capturePhoto()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.12)) { flash = false }
        }
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(AgriColors.white)

            Text(lang.t("camera.denied.title"))
                .font(AgriFont.bold(22))
                .foregroundStyle(AgriColors.white)

            Text(lang.t("camera.denied.msg"))
                .font(AgriFont.regular(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(AgriColors.white.opacity(0.8))
                .padding(.horizontal, 40)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(lang.t("camera.openSettings"))
                    .font(AgriFont.semibold(16))
                    .foregroundStyle(AgriColors.purple)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(AgriColors.white)
                    .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
            }
            .buttonStyle(.plain)
        }
    }
}

/// QR-style scan frame: dimmed surroundings, bold corner brackets, hint text below.
struct CameraScanFrame: View {
    var dimOpacity: CGFloat = 0.48
    var lineWidth: CGFloat = 5
    var bracketColor: Color = .white
    var hint: String = "Align the animal within the frame."

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.72
            let frame = CGRect(
                x: (geo.size.width - side) / 2,
                y: (geo.size.height - side) / 2 - geo.size.height * 0.06,
                width: side,
                height: side
            )

            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))

                ScanCornerBrackets()
                    .stroke(
                        bracketColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .position(x: frame.midX, y: frame.midY)
                    .animation(.easeInOut(duration: 0.2), value: bracketColor)
            }

            Text(hint)
                .font(AgriFont.regular(16))
                .foregroundStyle(AgriColors.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .position(x: geo.size.width / 2, y: frame.maxY + 34)
        }
    }
}

/// Four rounded L-shaped corner brackets forming a scan target.
private struct ScanCornerBrackets: Shape {
    var cornerLengthRatio: CGFloat = 0.20
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let len = min(rect.width, rect.height) * cornerLengthRatio
        let r = cornerRadius
        var path = Path()

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))

        return path
    }
}

// MARK: - Help

/// Bottom sheet that explains how to line the cow's muzzle up with the guide.
struct MuzzleHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            Text(lang.t("camera.guide.title"))
                .font(AgriFont.bold(22))
                .foregroundStyle(AgriColors.purpleDark)

            // Two example photos (placeholders for now – replace the asset names
            // "ExampleCorrect" / "ExampleWrong" with real images later).
            HStack(spacing: 14) {
                ExampleImageCard(
                    caption: lang.t("camera.guide.correct"),
                    tint: .green,
                    icon: "checkmark.circle.fill",
                    imageName: "ExampleCorrect"
                )
                ExampleImageCard(
                    caption: lang.t("camera.guide.wrong"),
                    tint: .red,
                    icon: "xmark.circle.fill",
                    imageName: "ExampleWrong"
                )
            }
            .padding(.horizontal, 20)

            Text(lang.t("camera.guide.body"))
                .font(AgriFont.regular(15))
                .foregroundStyle(AgriColors.purpleDark.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 14) {
                HelpRow(icon: "viewfinder", text: lang.t("camera.guide.tip1"))
                HelpRow(icon: "sun.max", text: lang.t("camera.guide.tip2"))
                HelpRow(icon: "hand.raised", text: lang.t("camera.guide.tip3"))
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Text(lang.t("camera.understand"))
                    .font(AgriFont.semibold(17))
                    .foregroundStyle(AgriColors.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(AgriColors.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgriColors.appBackground.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

/// A single rounded example image with a correct/wrong badge and caption.
private struct ExampleImageCard: View {
    let caption: String
    let tint: Color
    let icon: String
    let imageName: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.06))

                if UIImage(named: imageName) != nil {
                    Image(imageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.black.opacity(0.25))
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .padding(8)
                    .background(Circle().fill(AgriColors.white))
                    .padding(8)
            }

            Text(caption)
                .font(AgriFont.semibold(15))
                .foregroundStyle(tint)
        }
    }
}

/// A single instruction line with a purple icon.
private struct HelpRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AgriColors.purple)
                .frame(width: 24)
            Text(text)
                .font(AgriFont.regular(15))
                .foregroundStyle(AgriColors.purpleDark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Result

/// Testing sheet that shows the cropped muzzle (and the full photo for context).
struct MuzzleResultSheet: View {
    let cropped: UIImage?
    let full: UIImage?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            Text(lang.t("camera.result.title"))
                .font(AgriFont.bold(22))
                .foregroundStyle(AgriColors.purpleDark)

            ScrollView {
                VStack(spacing: 22) {
                    resultBlock(
                        title: lang.t("camera.result.cropped"),
                        image: cropped,
                        emptyText: lang.t("camera.result.noCrop")
                    )
                    resultBlock(
                        title: lang.t("camera.result.full"),
                        image: full,
                        emptyText: lang.t("camera.result.noPhoto")
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Button {
                dismiss()
            } label: {
                Text(lang.t("camera.done"))
                    .font(AgriFont.semibold(17))
                    .foregroundStyle(AgriColors.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(AgriColors.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgriColors.appBackground.ignoresSafeArea())
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func resultBlock(title: String, image: UIImage?, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AgriFont.semibold(15))
                .foregroundStyle(AgriColors.purpleDark)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 140)
                    .overlay(
                        Text(emptyText)
                            .font(AgriFont.regular(14))
                            .foregroundStyle(AgriColors.purpleDark.opacity(0.6))
                    )
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
extension CloudRunRecognitionService {
    /// A ready-state service for previews; never hits the network because
    /// previews don't trigger capture.
    static var preview: CloudRunRecognitionService {
        let s = CloudRunRecognitionService(
            baseURL: URL(string: "https://preview.invalid")!,
            tokenProvider: { "preview-token" }
        )
        s.status = .online
        return s
    }
}

#Preview {
    CameraScreen()
        .environmentObject(CloudRunRecognitionService.preview)
}
#endif
