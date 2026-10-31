// maildeep — does a deeply nested message survive on the 512 KB stack of a secondary thread?
//   maildeep <element> <depth> <what>      what: parse | walk | drop | bound
// Each run is one process, so a stack overflow is one crash (exit by signal), reported by the caller.
// Security verification N-6: SwiftSoup builds the whole tree before any depth limit of ours applies.
import Foundation
import SwiftSoup

let args = CommandLine.arguments
guard args.count == 4, let depth = Int(args[2]) else { print("usage: maildeep <div|span|b|table> <depth> <parse|walk|drop|bound>"); exit(2) }
let tag = args[1], what = args[3]
let open = tag == "table" ? "<table><tr><td>" : "<\(tag)>"
let html = "<html><body>" + String(repeating: open, count: depth) + "x" + "</body></html>"

/// The pre-parse bound: start tags outside comments, no credit for end tags. Never under-counts nesting.
func startTagBound(_ html: String) -> Int {
    var n = 0, inComment = false
    let u = Array(html.utf8); var i = 0
    while i < u.count {
        if inComment { if u[i] == 0x2D, i + 2 < u.count, u[i+1] == 0x2D, u[i+2] == 0x3E { inComment = false; i += 3; continue }; i += 1; continue }
        if u[i] == 0x3C, i + 1 < u.count {
            let c = u[i+1]
            if c == 0x21, i + 3 < u.count, u[i+2] == 0x2D, u[i+3] == 0x2D { inComment = true; i += 4; continue }
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { n += 1 }
        }
        i += 1
    }
    return n
}

final class Counter: NodeVisitor {
    var maxDepth = 0, nodes = 0
    func head(_ node: Node, _ depth: Int) throws { nodes += 1; if depth > maxDepth { maxDepth = depth } }
    func tail(_ node: Node, _ depth: Int) throws {}
}

var result = "no result"
let t = Thread {
    do {
        if what == "bound" { let a = Date(); let b = startTagBound(html); result = String(format: "bound=%d in %.2f ms for %d bytes", b, Date().timeIntervalSince(a) * 1000, html.utf8.count); return }
        var doc: Document? = try SwiftSoup.parse(html)
        if what == "parse" { result = "parsed; tree kept alive"; _ = Unmanaged.passRetained(doc!); return }
        if what == "walk" { let c = Counter(); try NodeTraversor(c).traverse(doc!); result = "walked \(c.nodes) nodes, depth \(c.maxDepth); tree kept alive"; _ = Unmanaged.passRetained(doc!); return }
        if what == "drop" { doc = nil; result = "parsed and released" }
    } catch { result = "threw \(error)" }
}
t.stackSize = 512 * 1024
let done = DispatchSemaphore(value: 0)
let wrapper = Thread { t.start(); while !t.isFinished { usleep(1000) }; done.signal() }
wrapper.start(); done.wait()
print("\(tag) × \(depth) · \(what) · 512 KB stack → \(result)")
