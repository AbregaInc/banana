#if os(macOS) && BANANA_AI && BANANA_BETA && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import CoreImage
import CoreImage.CIFilterBuiltins

enum DesktopPairingQRCode {
    private static let context = CIContext()

    static func image(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
#endif
