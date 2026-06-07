import AVFoundation
import SwiftUI
import UIKit

final class CameraModel: ObservableObject {
    enum Status {
        case idle
        case authorized
        case denied
    }

    @Published var status: Status = .idle
    @Published var lastPhoto: UIImage?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "carnivision.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var captureDelegate: PhotoCaptureDelegate?
    private var isConfigured = false

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

                self.session.commitConfiguration()
                self.isConfigured = true
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning else { return }

            let delegate = PhotoCaptureDelegate { [weak self] image in
                DispatchQueue.main.async {
                    self?.lastPhoto = image
                    self?.captureDelegate = nil
                }
            }
            self.captureDelegate = delegate
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
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
    @State private var flash = false
    @State private var showHelp = false

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

            if model.status == .authorized {
                CameraScanFrame()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if flash {
                Color.white.ignoresSafeArea()
            }

            overlayControls
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showHelp) {
            MuzzleHelpSheet()
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button {
                    showHelp = true
                } label: {
                    Text("Help?")
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

            Spacer()

            if model.status == .authorized {
                Button(action: capture) {
                    ZStack {
                        Circle()
                            .stroke(CarniColors.white, lineWidth: 5)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(CarniColors.white)
                            .frame(width: 62, height: 62)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 36)
            }
        }
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

            Text("Camera access needed")
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.white)

            Text("Allow camera access in Settings to scan animals.")
                .font(CarniFont.regular(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(CarniColors.white.opacity(0.8))
                .padding(.horizontal, 40)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
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
                        Color.white,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .position(x: frame.midX, y: frame.midY)
            }

            Text("Align the animal within the frame.")
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

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            Text("Scanning guide")
                .font(CarniFont.bold(22))
                .foregroundStyle(CarniColors.purpleDark)

            // Two example photos (placeholders for now – replace the asset names
            // "ExampleCorrect" / "ExampleWrong" with real images later).
            HStack(spacing: 14) {
                ExampleImageCard(
                    caption: "Correct",
                    tint: .green,
                    icon: "checkmark.circle.fill",
                    imageName: "ExampleCorrect"
                )
                ExampleImageCard(
                    caption: "Wrong",
                    tint: .red,
                    icon: "xmark.circle.fill",
                    imageName: "ExampleWrong"
                )
            }
            .padding(.horizontal, 20)

            Text("Place the animal inside the white square on your screen. It does not need to be perfect — as long as it stays within the frame, the scan should work.")
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 14) {
                HelpRow(icon: "viewfinder", text: "Move closer or farther until the subject fits comfortably inside the square.")
                HelpRow(icon: "sun.max", text: "Find good lighting and hold your phone steady before taking the photo.")
                HelpRow(icon: "hand.raised", text: "Keep the subject fully inside the frame — avoid cutting it off at the edges.")
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Text("I understand")
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
