import CoreGraphics
import Foundation
import ImageIO
import Vision
#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A photo of a package, picked from Photos instead of taken live: the barcodes in it, read the
/// way the camera scanner reads them. A photo with a barcode is that product; one without goes to
/// its label (`NutritionLabelReader`).
enum PackagePhoto {
    /// Upright, no bigger than reading a label or a barcode needs.
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2400]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The product barcodes in the photo, each once, in the order Vision found them. The same
    /// kinds the camera scanner reads (`BarcodeScannerView`).
    static func barcodes(in image: CGImage) async -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.ean8, .ean13, .upce, .code128, .itf14]
        guard let found = try? await request.perform(on: image) else { return [] }
        var codes: [String] = []
        for observation in found {
            guard let payload = observation.payloadString,
                  let code = try? BarcodeProductLookup.normalizedBarcode(payload),
                  !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes
    }

    #if DEBUG
    /// A Code 128 barcode on a white page, as a photo of a package would show one: for tests and
    /// `--grocery-photo-codes`, where there's no photo library to pick from.
    static func barcodePicture(_ code: String?) -> Data? {
        let context = CIContext()
        let page = CGRect(x: 0, y: 0, width: 900, height: 600)
        var picture = CIImage(color: .white).cropped(to: page)
        if let code {
            let generator = CIFilter.code128BarcodeGenerator()
            generator.message = Data(code.utf8)
            generator.quietSpace = 10
            if let bars = generator.outputImage {
                let scaled = bars.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                let at = CGAffineTransform(translationX: (page.width - scaled.extent.width) / 2,
                                           y: (page.height - scaled.extent.height) / 2)
                picture = scaled.transformed(by: at).composited(over: picture)
            }
        }
        return context.pngRepresentation(of: picture, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    #endif
}
