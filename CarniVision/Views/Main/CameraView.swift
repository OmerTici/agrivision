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
    /// Seconds remaining on the hold countdown (nil when not counting down).
    @Published var countdown: Int?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "carnivision.camera.session")
    private let videoQueue = DispatchQueue(label: "carnivision.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var isConfigured = false

    // Detection / auto-capture state (touched only on videoQueue).
    private let cowDetector = CowDetectorService()
    private let muzzleDetector = MuzzleDetectorService()
    private var isAnalyzing = false
    private var hasAutoCaptured = false
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
    // The live gate uses a COCO YOLO11n detector and keys on the whole-animal
    // "cow" box, so the geometry is loose: a close cow can fill the frame and
    // touch the edges. The muzzle is localized separately on the captured still.

    private let edgeMargin: CGFloat = 0.0
    /// How long a qualifying cow must be held steady before auto-capture.
    private let holdDuration: TimeInterval = 2.0

    /// Minimum confidence for the live preview gate. COCO "cow" scores run
    /// ~0.3–0.9 depending on framing, so the floor is kept modest.
    private let cowConfidenceThreshold: Float = 0.35
    /// Floor for cropping a muzzle from the captured still — a box below this is
    /// noise, and failing the scan beats enrolling a junk crop.
    private let muzzleConfidenceThreshold: Float = 0.25
    private let minCowBoxWidth: CGFloat = 0.05
    private let minCowBoxHeight: CGFloat = 0.05
    private let maxCowBoxWidth: CGFloat = 1.0
    private let maxCowBoxHeight: CGFloat = 1.0
    private let cowCenterRange: ClosedRange<CGFloat> = 0.02...0.98

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
        }
        videoQueue.async { [weak self] in
            self?.isAutomaticMode = mode == .automatic
            self?.qualifyingSince = nil
            self?.hasAutoCaptured = false
        }
    }

    private func resetLiveDetectionState() {
        videoQueue.async { [weak self] in
            self?.qualifyingSince = nil
            self?.hasAutoCaptured = false
            self?.lastCowHit = nil
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

    func capturePhoto() {
        if captureMode == .manual && !canManualCapture { return }

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

    /// Runs muzzle detection on the captured still and crops to the detected muzzle box.
    private func processCapturedPhoto(_ image: UIImage?) {
        videoQueue.async { [weak self] in
            guard let self else { return }

            guard let cgImage = image?.normalizedCGImage() else {
                self.finishFailure("camera.fail.read")
                return
            }

            let detections = self.muzzleDetector.detections(in: cgImage, orientation: .up)
            let best = detections.max(by: { $0.confidence < $1.confidence })
            guard let best,
                  best.confidence >= self.muzzleConfidenceThreshold,
                  let crop = self.muzzleDetector.cropMuzzle(from: cgImage, boundingBox: best.boundingBox)
            else {
                self.finishFailure("camera.fail.crop")
                return
            }

            let box = best.boundingBox
            let readout = String(
                format: "Photo muzzle conf %.2f · size %.0f%%×%.0f%%",
                best.confidence,
                box.width * 100,
                box.height * 100
            )
            self.finishSuccess(crop: crop, readout: readout)
        }
    }

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

    private func finishFailure(_ messageKey: String) {
        DispatchQueue.main.async {
            self.croppedMuzzle = nil
            self.debugReadout = messageKey
            self.isProcessing = false
            self.captureSucceeded = false
            self.failureMessage = messageKey
            self.captureFailed = true
            self.canManualCapture = false
        }
        resetLiveDetectionState()
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

        if isAutomaticMode {
            processAutomaticFrame(pixelBuffer)
        } else {
            processManualFrame(pixelBuffer)
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
            }
        }

        let counting = qualifyingSince != nil
        let remaining = qualifyingSince.map { holdDuration - now.timeIntervalSince($0) } ?? holdDuration
        let countdownValue: Int? = counting ? max(1, Int(ceil(remaining))) : nil
        let showGreen = cowStable || counting

        let readout: String
        if counting, let cowBest {
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
        } else {
            readout = Self.idleReadout
        }

        DispatchQueue.main.async { [weak self] in
            self?.cowVisible = showGreen
            self?.debugReadout = readout
            self?.countdown = countdownValue
        }

        if counting, remaining <= 0 {
            hasAutoCaptured = true
            DispatchQueue.main.async { [weak self] in
                self?.countdown = nil
                self?.capturePhoto()
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
        guard box.width >= minCowBoxWidth, box.height >= minCowBoxHeight else { return false }
        guard box.width <= maxCowBoxWidth, box.height <= maxCowBoxHeight else { return false }

        let aspect = box.width / max(box.height, 0.001)
        if aspect > 3.5, box.width > 0.45 { return false }

        guard box.minX >= edgeMargin, box.minY >= edgeMargin,
              box.maxX <= 1 - edgeMargin, box.maxY <= 1 - edgeMargin else { return false }

        return cowCenterRange.contains(box.midX) && cowCenterRange.contains(box.midY)
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

struct CameraScreen: View {
    var onClose: () -> Void = {}

    @StateObject private var model = CameraModel()
    @ObservedObject private var lang = LanguageManager.shared
    @State private var flash = false
    @State private var showHelp = false
    @State private var showResult = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.status {
            case .authorized:
                CameraPreviewView(session: model.session)
                    .ignoresSafeArea()
            case .denied:
                deniedView
            case .idle:
                ProgressView()
                    .tint(CarniColors.white)
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

                if model.captureMode == .automatic || model.captureMode == .manual || model.isProcessing {
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
        }
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
        .sheet(isPresented: $showHelp) {
            MuzzleHelpSheet()
        }
        .sheet(isPresented: $showResult) {
            MuzzleResultSheet(cropped: model.croppedMuzzle, full: model.lastPhoto)
        }
    }

    private var scanBracketColor: Color {
        switch model.captureMode {
        case .automatic:
            return model.cowVisible ? CarniColors.successGreen : .white
        case .manual:
            return model.canManualCapture ? CarniColors.successGreen : .white
        }
    }

    private var scanHint: String {
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
                        .font(CarniFont.semibold(15))
                        .foregroundStyle(CarniColors.white)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(CarniColors.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if model.status == .authorized && !model.showsResultOverlay {
                captureModePicker
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
            }

            Spacer()

            if model.status == .authorized && !model.showsResultOverlay && model.captureMode == .manual {
                Button(action: capture) {
                    ZStack {
                        Circle()
                            .stroke(CarniColors.white, lineWidth: 5)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(CarniColors.white)
                            .frame(width: 62, height: 62)
                        if model.isProcessing {
                            ProgressView()
                                .tint(CarniColors.purple)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isProcessing || !model.canManualCapture)
                .opacity(model.canManualCapture && !model.isProcessing ? 1 : 0.35)
                .padding(.bottom, 36)
            }
        }
    }

    private var captureModePicker: some View {
        HStack(spacing: 0) {
            ForEach(CameraModel.CaptureMode.allCases, id: \.self) { mode in
                Button {
                    model.setCaptureMode(mode)
                } label: {
                    Text(lang.t(mode.key))
                        .font(CarniFont.semibold(14))
                        .foregroundStyle(
                            model.captureMode == mode ? CarniColors.purpleDark : CarniColors.white
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            model.captureMode == mode
                                ? CarniColors.white
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
                            .foregroundStyle(CarniColors.purpleDark.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: model.captureSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(model.captureSucceeded ? CarniColors.successGreen : .red)

                Text(lang.t(model.captureSucceeded ? "camera.success.title" : "camera.failed.title"))
                    .font(CarniFont.bold(22))
                    .foregroundStyle(CarniColors.purpleDark)

                Text(lang.t(model.captureSucceeded ? "camera.success.msg" : model.failureMessage))
                    .font(CarniFont.regular(15))
                    .foregroundStyle(CarniColors.purpleDark.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

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
                                .font(CarniFont.semibold(17))
                                .foregroundStyle(CarniColors.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(CarniColors.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        model.scanAgain()
                    } label: {
                        Text(lang.t("camera.scanAgain"))
                            .font(CarniFont.semibold(16))
                            .foregroundStyle(CarniColors.purple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(CarniColors.purple.opacity(0.4), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(CarniColors.appBackground)
            )
            .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
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
                .foregroundStyle(CarniColors.white)

            Text(lang.t("camera.denied.title"))
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.white)

            Text(lang.t("camera.denied.msg"))
                .font(CarniFont.regular(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(CarniColors.white.opacity(0.8))
                .padding(.horizontal, 40)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(lang.t("camera.openSettings"))
                    .font(CarniFont.semibold(16))
                    .foregroundStyle(CarniColors.purple)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(CarniColors.white)
                    .clipShape(RoundedRectangle(cornerRadius: CarniLayout.buttonCornerRadius))
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
                .font(CarniFont.regular(16))
                .foregroundStyle(CarniColors.white)
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
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.purpleDark)

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
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark.opacity(0.9))
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
                    .font(CarniFont.semibold(17))
                    .foregroundStyle(CarniColors.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(CarniColors.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CarniColors.appBackground.ignoresSafeArea())
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
                    .background(Circle().fill(CarniColors.white))
                    .padding(8)
            }

            Text(caption)
                .font(CarniFont.semibold(15))
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
                .foregroundStyle(CarniColors.purple)
                .frame(width: 24)
            Text(text)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
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
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.purpleDark)

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
                    .font(CarniFont.semibold(17))
                    .foregroundStyle(CarniColors.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(CarniColors.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CarniColors.appBackground.ignoresSafeArea())
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func resultBlock(title: String, image: UIImage?, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CarniFont.semibold(15))
                .foregroundStyle(CarniColors.purpleDark)

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
                            .font(CarniFont.regular(14))
                            .foregroundStyle(CarniColors.purpleDark.opacity(0.6))
                    )
            }
        }
    }
}
