// Is Gmail's multipart batch endpoint needed for round trips, when URLSession multiplexes?
// Unauthenticated on purpose: every call answers 401, so this measures the transport only
// (protocol negotiated, connections used, round-trip overhead) — not Gmail's own work per call.
import Foundation

final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let lock = NSLock()
    var protocols: [String: Int] = [:], reused = 0, fresh = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        for t in metrics.transactionMetrics {
            protocols[t.networkProtocolName ?? "?", default: 0] += 1
            if t.isReusedConnection { reused += 1 } else { fresh += 1 }
        }
    }
}
let metrics = Metrics()
let config = URLSessionConfiguration.ephemeral
config.requestCachePolicy = .reloadIgnoringLocalCacheData
config.httpMaximumConnectionsPerHost = 6
let session = URLSession(configuration: config, delegate: metrics, delegateQueue: nil)
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func load() -> String { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return String(format: "load %.0f %.0f %.0f", l[0], l[1], l[2]) }

func single(_ i: Int) async -> Int {
    var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/18c0000000\(i)?format=minimal")!)
    r.setValue("Banana-probe (gzip)", forHTTPHeaderField: "User-Agent")
    return ((try? await session.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? -1
}
func parallel(_ n: Int) async -> (ms: Double, statuses: [Int: Int]) {
    let a = now()
    let tasks = (0..<n).map { i in Task { await single(i) } }
    var statuses: [Int: Int] = [:]
    for t in tasks { statuses[await t.value, default: 0] += 1 }
    return (Double(now() - a) / 1e6, statuses)
}
func batch(_ n: Int) async -> (ms: Double, outer: Int, parts: Int, bytes: Int) {
    let boundary = "batch_banana_probe"
    var body = ""
    for i in 0..<n {
        body += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <item\(i)>\r\n\r\nGET /gmail/v1/users/me/messages/18c0000000\(i)?format=minimal\r\n\r\n"
    }
    body += "--\(boundary)--\r\n"
    var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!)
    r.httpMethod = "POST"
    r.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    r.setValue("Banana-probe (gzip)", forHTTPHeaderField: "User-Agent")
    r.httpBody = Data(body.utf8)
    let a = now()
    guard let (data, response) = try? await session.data(for: r) else { return (-1, -1, 0, 0) }
    let text = String(decoding: data, as: UTF8.self)
    return (Double(now() - a) / 1e6, (response as? HTTPURLResponse)?.statusCode ?? -1, text.components(separatedBy: "HTTP/1.1 401").count - 1, data.count)
}

print(load())
_ = await single(999)                      // open the connection once; both shapes then start warm
var p: [Double] = [], b: [Double] = [], s: [Double] = []
for round in 0..<6 {
    let one = now(); _ = await single(round); s.append(Double(now() - one) / 1e6)
    let par = await parallel(20); p.append(par.ms)
    let bat = await batch(20); b.append(bat.ms)
    if round == 0 { print("round 0: 20 parallel GETs statuses \(par.statuses); batch outer \(bat.outer), inner 401 parts \(bat.parts), \(bat.bytes) bytes") }
}
session.finishTasksAndInvalidate()
try? await Task.sleep(nanoseconds: 300_000_000)
func med(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
print(String(format: "one GET, warm connection:        median %.0f ms  (all: %@)", med(s), s.map { String(format: "%.0f", $0) }.joined(separator: " ")))
print(String(format: "20 GETs at once, one session:    median %.0f ms  (all: %@)", med(p), p.map { String(format: "%.0f", $0) }.joined(separator: " ")))
print(String(format: "one batch of 20 (multipart):     median %.0f ms  (all: %@)", med(b), b.map { String(format: "%.0f", $0) }.joined(separator: " ")))
print("protocols: \(metrics.protocols) · connections opened \(metrics.fresh), requests on a reused connection \(metrics.reused)")
print(load())
