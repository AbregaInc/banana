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

    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce, .code128, .itf14])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.view.accessibilityIdentifier = "wellness.barcodeScanner"
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            onError("The camera scanner is unavailable. You can still enter the product manually.")
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parent: BarcodeScannerView
        private var completed = false
        private var last: String?

        init(parent: BarcodeScannerView) { self.parent = parent }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !completed,
                  case .barcode(let barcode) = addedItems.first,
                  let value = barcode.payloadStringValue else { return }
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
            guard !completed else { return }
            completed = true
            parent.onError("The camera scanner became unavailable. You can still enter the product manually.")
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
