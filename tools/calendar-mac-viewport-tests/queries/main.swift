import SwiftUI
import Foundation
#if os(macOS)
import AppKit
typealias Attributes = NSCollectionViewLayoutAttributes
func attribute(_ i: Int) -> Attributes { .init(forItemWith: IndexPath(item: i, section: 0)) }
#else
import UIKit
typealias Attributes = UICollectionViewLayoutAttributes
func attribute(_ i: Int) -> Attributes { .init(forCellWith: IndexPath(item: i, section: 0)) }
#endif
@inline(never) func reference(_ attrs: [Attributes], rect: CGRect, active: Int?) -> [Attributes] {
    let pinned = active.flatMap { attrs.indices.contains($0) ? attrs[$0] : nil }
    return attrs.filter { $0 === pinned || $0.frame.intersects(rect) }
}
@inline(never) func separateFrames(_ attrs: [Attributes], frames: [CGRect], rect: CGRect, active: Int?) -> [Attributes] {
    var hits: [Attributes] = []
    for index in frames.indices where index == active || frames[index].intersects(rect) {
        hits.append(attrs[index])
    }
    return hits
}
func cpu() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
}
let rects = (0..<24).map { i in CGRect(x: 50 + i * 25, y: (i % 4) * 56 + 300, width: 360, height: 670) }
for count in [0,1,25,100,300,1000,5000,10000] {
    let rows = (0..<count).map { i in
        Row(id: "event-\(i)", frame: CGRect(x: (i % 7) * 142 + 45, y: (i * 127) % 1370,
                                           width: 132, height: 26 + i % 73), content: { AnyView(EmptyView()) })
    }
    let attributes = rows.enumerated().map { i, row in
        let a = attribute(i); a.frame = row.frame; return a
    }
    for active in [nil, count > 0 ? count - 1 : -1] as [Int?] {
        let oracle = rects.map { reference(attributes,rect:$0,active:active) }
        for trial in 0..<13 {
            for step in 0..<3 {
                let mode = (step+trial)%3
                let start = ProcessInfo.processInfo.systemUptime
                let cpuStart = cpu()
                // Include preparing an extra frame array once per full set of 24 scroll queries.
                let frames = mode == 2 ? rows.map(\.frame) : []
                let queryStart = ProcessInfo.processInfo.systemUptime
                let values = rects.map { rect in
                    switch mode {
                    case 0: return reference(attributes,rect:rect,active:active)
                    case 1: return CalendarViewportAttributes.visible(attributes, items: rows, rect: rect, active: active, frame: \.frame)
                    default: return separateFrames(attributes,frames:frames,rect:rect,active:active)
                    }
                }
                let finish = ProcessInfo.processInfo.systemUptime
                let cpuMS = (cpu()-cpuStart)*1000
                for (a,b) in zip(oracle,values) { precondition(a.count==b.count && zip(a,b).allSatisfy { $0 === $1 }) }
                let r:[String:Any]=["count":count,"mode":mode,"trial":trial,"active":active != nil,
                    "ms":(finish-start)*1000,"cpuMS":cpuMS,"queryMS":(finish-queryStart)*1000/24,
                    "hits":values.map(\.count),"rowStride":MemoryLayout<Row>.stride,"extraBytes":frames.count*MemoryLayout<CGRect>.stride]
                print(String(decoding:try JSONSerialization.data(withJSONObject:r,options:.sortedKeys),as:UTF8.self))
            }
        }
    }
}
