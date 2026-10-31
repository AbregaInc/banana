import AppKit
import SwiftUI
// What the system gives for the composer's body: AttributedString (bold, italic, underline,
// strikethrough, link) -> HTML, and whether that needs the main thread.
var a = AttributedString("Thanks — I'll look at it ")
var b = AttributedString("tonight"); b.inlinePresentationIntent = .stronglyEmphasized
var c = AttributedString(" and "); 
var d = AttributedString("send notes"); d.link = URL(string: "https://example.com/notes?a=1&b=<2>")!; d.underlineStyle = .single
var e = AttributedString(".\nSecond paragraph, struck"); e.strikethroughStyle = .single
a += b; a += c; a += d; a += e
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    let ns = try! NSAttributedString(a, including: \.appKit)
    let t0 = DispatchTime.now().uptimeNanoseconds
    let data = try! ns.data(from: NSRange(location: 0, length: ns.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    let t1 = DispatchTime.now().uptimeNanoseconds
    let html = String(decoding: data, as: UTF8.self)
    print("system HTML writer, off the main thread: \(data.count) bytes for \(ns.length) characters, \(Double(t1 - t0) / 1e6) ms, isMainThread=\(Thread.isMainThread)")
    print(html)
    done.signal()
}
done.wait()
// The inline intents the composer needs are all plain Foundation attributes:
for run in a.runs {
    let text = String(a[run.range].characters).replacingOccurrences(of: "\n", with: "\\n")
    print("run:", "\"\(text)\"", "bold:", run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false, "link:", run.link?.absoluteString ?? "-")
}
