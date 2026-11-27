import Foundation
import Darwin
func footprint() -> Double {
    var i = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout.size(ofValue: i)/4)
    let status = withUnsafeMutablePointer(to: &i) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
        }
    }
    precondition(status == KERN_SUCCESS)
    return Double(i.phys_footprint) / 1_048_576
}
let rich = Int(CommandLine.arguments[1])!
let count = 60_000
let start = ProcessInfo.processInfo.systemUptime
var bodies: [MailMessageID: MailBody] = [:]
bodies.reserveCapacity(count)
for i in 0..<count {
    let key = MailMessageID(account:"reader@example.test",message:String(i))
    let text = MailTextRun(text:"Item \(i)",link:nil)
    let picture = i % 100 < rich
    let block = MailTextBlock(kind:picture ? .picture(MailPicture(source:.cid("part-\(i)"))) : .paragraph,runs:picture ? [] : [text])
    let body = MailText(blocks:[block])
    bodies[key] = picture ? .designed(document:"<p>\(i)</p>",pictures:MailPictures(boxes:[],waiting:0,trackersRemoved:0),hasQuote:false,plain:body,notices:[]) : .text(body,quoteStartsAt:nil,notices:[])
}
let built = ProcessInfo.processInfo.systemUptime
let used = footprint()
var checked = 0
var digest = 0
for i in 0..<count {
    let key = MailMessageID(account:"reader@example.test",message:String(i))
    switch bodies[key] {
    case .text(let t, _, _):
        precondition(t.blocks[0].runs[0].text == "Item \(i)")
        digest += t.blocks[0].runs[0].text.utf8.count
    case .designed(let html, _, _, let t, _):
        guard case .picture(let p) = t.blocks[0].kind, case .cid(let id) = p.source else { fatalError() }
        precondition(id == "part-\(i)" && html == "<p>\(i)</p>")
        digest += html.utf8.count + id.utf8.count
    default: fatalError()
    }
    checked += 1
}
let end = ProcessInfo.processInfo.systemUptime
print(rich,checked,digest,used,(built-start)*1000,(end-built)*1000,MemoryLayout<MailBody>.stride,MemoryLayout<MailTextBlock>.stride)
