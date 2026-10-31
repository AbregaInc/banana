#if os(iOS)
// The capture session and its parts aren't marked Sendable; their work is done on the camera's queue.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Banana's camera for a meal photo with its depth in the file — the LiDAR's on a phone or iPad
/// that has it, else the two back cameras' — so the plate and the food can be measured
/// (`MealPhotoDepth`, docs/design/MEAL-LEARNING.md §8). `UIImagePickerController` can't capture
/// depth. Preview, shutter, Cancel; nothing else.
@MainActor
final class MealDepthCamera: NSObject, ObservableObject {
    enum State { case starting, ready, capturing, denied, failed }

    /// The back cameras that can capture depth, best first.
    nonisolated private static let kinds: [AVCaptureDevice.DeviceType] = [
        .builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera,
    ]

    /// The best depth camera here: nil on the Simulator and on phones with one back camera.
    nonisolated static func device() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: .video, position: .back).devices
        for kind in kinds {
            if let device = found.first(where: { $0.deviceType == kind }),
               device.formats.contains(where: { !$0.supportedDepthDataFormats.isEmpty }) { return device }
        }
        return nil
    }

    /// Whether "Take a photo" opens this camera or the system's. Looked up once.
    nonisolated static let isAvailable = device() != nil

    @Published private(set) var state = State.starting
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// The session's work blocks: never on the main thread.
    private let queue = DispatchQueue(label: "com.boris.banana.meal-camera")
    private var device: AVCaptureDevice?
    private var preview: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?
    private var onPhoto: ((Data) -> Void)?

    /// Which camera the photos come from, for what's kept of their depth.
    var source: PhotoDepth.Source { device?.deviceType == .builtInLiDARDepthCamera ? .lidar : .portrait }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        default:
            state = .denied
            return
        }
        guard let device = Self.device() else {
            state = .failed
            return
        }
        self.device = device
        let ready = await withCheckedContinuation { continuation in
            queue.async { [session, output] in
                let ready = Self.configure(session, output: output, device: device)
                if ready { session.startRunning() }
                continuation.resume(returning: ready)
            }
        }
        state = ready ? .ready : .failed
        keepLevel()
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The preview on screen, kept level with the horizon however the device is held.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        preview = layer
        keepLevel()
    }

    private func keepLevel() {
        guard rotation == nil, let device, let preview else { return }
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        self.rotation = rotation
        rotationWatch = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.turnPreview(to: angle) }
        }
    }

    private func turnPreview(to angle: CGFloat) {
        guard let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Takes the photo: HEIC with the depth map inside, upright by its orientation tag.
    func capture(_ onPhoto: @escaping (Data) -> Void) {
        guard state == .ready else { return }
        state = .capturing
        self.onPhoto = onPhoto
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        queue.async { [output] in
            let settings = output.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) : AVCapturePhotoSettings()
            settings.isDepthDataDeliveryEnabled = output.isDepthDataDeliveryEnabled
            settings.embedsDepthDataInPhoto = output.isDepthDataDeliveryEnabled
            settings.isDepthDataFiltered = true
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            if let angle, let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finished(_ data: Data?) {
        state = .ready
        guard let data, let onPhoto else { return }
        self.onPhoto = nil
        onPhoto(data)
    }

    /// The camera, a photo output that delivers depth, and a format that has it. False when this
    /// camera won't give depth after all.
    nonisolated private static func configure(_ session: AVCaptureSession, output: AVCapturePhotoOutput,
                                              device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input),
              session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // The photo preset may pick a format without depth (the LiDAR camera's does): then the
            // one with the most depth readings, at least big enough for the copy kept.
            if device.activeFormat.supportedDepthDataFormats.isEmpty {
                let withDepth = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
                let bigEnough = withDepth.filter { $0.formatDescription.dimensions.width >= 1_920 }
                guard let format = (bigEnough.isEmpty ? withDepth : bigEnough).max(by: { depthWidth($0) < depthWidth($1) })
                else { return false }
                device.activeFormat = format
            }
            // Depth in metres rather than disparity, as large as it comes.
            let metres: Set<FourCharCode> = [kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DepthFloat16]
            let depths = device.activeFormat.supportedDepthDataFormats
            if let best = depths.filter({ metres.contains($0.formatDescription.mediaSubType.rawValue) })
                .max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }) {
                device.activeDepthDataFormat = best
            }
        } catch {
            return false
        }
        guard output.isDepthDataDeliverySupported else { return false }
        output.isDepthDataDeliveryEnabled = true
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            output.maxPhotoDimensions = largest
        }
        return true
    }

    nonisolated private static func depthWidth(_ format: AVCaptureDevice.Format) -> Int32 {
        format.supportedDepthDataFormats.map(\.formatDescription.dimensions.width).max() ?? 0
    }
}

extension MealDepthCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in self.finished(data) }
    }
}

/// The camera on screen. Hands back the photo's file, depth inside, and which camera took it.
struct MealDepthCameraView: View {
    var onPhoto: (Data, PhotoDepth.Source) -> Void
    @StateObject private var camera = MealDepthCamera()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Preview(camera: camera).ignoresSafeArea()
            VStack(spacing: DS.Space.l) {
                Spacer()
                message
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("mealCamera.cancel")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    shutter
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Space.xl)
            }
            .padding(.bottom, DS.Space.xl)
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder private var message: some View {
        switch camera.state {
        case .denied:
            VStack(spacing: DS.Space.s) {
                Text("Banana can't use the camera.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
            }
            .font(.callout)
            .foregroundStyle(.white)
        case .failed:
            Text("The camera isn't available right now.").font(.callout).foregroundStyle(.white)
        default:
            // The plate is measured across, so all of it has to be in the photo.
            Text("From above, with the whole plate in view")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var shutter: some View {
        Button {
            camera.capture { data in
                onPhoto(data, camera.source)
                dismiss()
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(.white).frame(width: 62, height: 62)
                    .opacity(camera.state == .capturing ? 0.4 : 1)
            }
        }
        .disabled(camera.state != .ready)
        .accessibilityLabel("Take photo")
        .accessibilityIdentifier("mealCamera.shutter")
    }

    private struct Preview: UIViewRepresentable {
        let camera: MealDepthCamera

        func makeUIView(context: Context) -> PreviewView {
            let view = PreviewView()
            view.preview.session = camera.session
            view.preview.videoGravity = .resizeAspectFill
            camera.attach(view.preview)
            return view
        }

        func updateUIView(_ view: PreviewView, context: Context) {}

        final class PreviewView: UIView {
            override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
            /// Always that, by `layerClass`.
            var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        }
    }
}
#endif
