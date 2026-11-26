import Foundation
import PDFKit
import Vision
import AppKit
// usage: extract <file> -> text on stdout. PDF via PDFKit; images via Vision OCR (accurate).
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let ext = url.pathExtension.lowercased()
if ext == "pdf" {
    var text = PDFDocument(url: url)?.string ?? ""
    if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, let doc = PDFDocument(url: url) {
        // Scanned PDF: OCR the first pages.
        for i in 0..<min(doc.pageCount, 5) {
            guard let page = doc.page(at: i) else { continue }
            let image = page.thumbnail(of: NSSize(width: 1600, height: 2000), for: .mediaBox)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate
                try? VNImageRequestHandler(cgImage: cg).perform([r])
                text += (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
        }
    }
    print(text)
} else {
    let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate
    try? VNImageRequestHandler(url: url).perform([r])
    print((r.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
}
