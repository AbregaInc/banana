#if BANANA_MODULE_FOOD || (BANANA_AI && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT)
#if os(iOS)
import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (String) -> Void
    /// Keeps scanning after a read, for a bag of shopping: each code is reported once, until a
    /// different one has been read in between.
    var continuous = false
    var symbologies: [VNBarcodeSymbology] = [.ean8, .ean13, .upce, .code128, .itf14]
    var accepts: (String) -> Bool = { _ in true }
    var accessibilityID = "wellness.barcodeScanner"
    var unavailableMessage = "The camera scanner is unavailable. You can still enter the product manually."

    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.view.accessibilityIdentifier = accessibilityID
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.completed else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.fail()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parent: BarcodeScannerView
        private(set) var completed = false
        private var last: String?

        init(parent: BarcodeScannerView) { self.parent = parent }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !completed,
                  case .barcode(let barcode) = addedItems.first,
                  let value = barcode.payloadStringValue, parent.accepts(value) else { return }
            if parent.continuous {
                // The same package still in view, or picked up again: once.
                guard value != last else { return }
                last = value
            } else {
                completed = true
                dataScanner.stopScanning()
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            parent.onScan(value)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            fail()
        }

        func fail() {
            guard !completed else { return }
            completed = true
            Task { @MainActor in parent.onError(parent.unavailableMessage) }
        }
    }
}

@MainActor
func requestBarcodeCameraAccess() async -> Bool {
    guard BarcodeScannerView.isSupported else { return false }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted: return false
    @unknown default: return false
    }
}
#endif
#endif
