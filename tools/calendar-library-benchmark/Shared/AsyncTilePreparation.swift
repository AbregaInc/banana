import Foundation
import CoreGraphics

/// Foreground page preparation on native Swift concurrency workers. No view or layer
/// crosses the worker boundary. Cancellation propagates through the structured group.
@MainActor
final class AsyncTilePreparation {
    struct Request: Sendable {
        let key: RasterKey
        let region: CGRect
    }
    struct Result: Sendable {
        let key: RasterKey
        let page: RasterPage
    }
    let workers: Int
    private let queues: [DispatchQueue]
    private var dispatchCancellation: Operation?
    private var work: Task<[Result], Never>?
    private var generation = 0
    var isPreparing: Bool { work != nil }
    private(set) var dispatchMS = 0.0

    init(workers: Int) {
        precondition((1...2).contains(workers))
        self.workers = workers
        queues = CalendarFixtureConfiguration().args.contains("--foreground-dispatch") ? (0..<workers).map {
            DispatchQueue(label: "Calendar foreground raster \($0)", qos: .userInitiated)
        } : []
    }
    func cancel() {
        generation &+= 1
        work?.cancel()
        dispatchCancellation?.cancel()
        work = nil
    }
    func prepare(_ requests: [Request], days: [DayGeometry], width: CGFloat,
                 height: CGFloat, gutter: CGFloat, scale: CGFloat,
                 style: RasterPage.Style) async -> [Result]? {
        guard !Task.isCancelled else { return nil }
        let began = DispatchTime.now().uptimeNanoseconds
        cancel()
        dispatchMS = 0
        let token = generation, workers = workers, queues = queues
        guard !requests.isEmpty else { return [] }
        let cancellation = Operation()
        dispatchCancellation = cancellation
        let task = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: [Result].self, returning: [Result].self) { group in
                // At most two child tasks; do not create a task for every event or tile.
                for worker in 0..<min(workers, requests.count) {
                    group.addTask {
                        if !queues.isEmpty {
                            return await withCheckedContinuation { continuation in
                                queues[worker].async {
                                    let memo = style.textMemo(reusing: (requests.count + workers - 1 - worker) / workers)
                                    var result: [Result] = []
                                    for index in stride(from: worker, to: requests.count, by: workers) {
                                        guard !cancellation.isCancelled else { continuation.resume(returning: []); return }
                                        let request = requests[index]
                                        let page = autoreleasepool {
                                            RasterPage.render(days: days, width: width, height: height,
                                                gutter: gutter, scale: scale, style: style, region: request.region,
                                                cancelled: { cancellation.isCancelled }, textMemo: memo)
                                        }
                                        guard !cancellation.isCancelled, let page else { continuation.resume(returning: []); return }
                                        result.append(Result(key: request.key, page: page))
                                    }
                                    continuation.resume(returning: result)
                                }
                            }
                        }
                        let memo = style.textMemo(reusing: (requests.count + workers - 1 - worker) / workers)
                        var result: [Result] = []
                        for index in stride(from: worker, to: requests.count, by: workers) {
                            guard !Task.isCancelled else { return [] }
                            let request = requests[index]
                            let page = autoreleasepool {
                                RasterPage.render(days: days, width: width, height: height,
                                    gutter: gutter, scale: scale, style: style, region: request.region, textMemo: memo)
                            }
                            guard !Task.isCancelled, let page else { return [] }
                            result.append(Result(key: request.key, page: page))
                        }
                        return result
                    }
                }
                var result: [Result] = []
                for await pages in group { result.append(contentsOf: pages) }
                return result
            }
        }
        work = task
        dispatchMS = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        let result = await withTaskCancellationHandler(operation: { await task.value },
                                                       onCancel: { task.cancel(); cancellation.cancel() })
        if token == generation { work = nil }
        guard token == generation, !task.isCancelled, !Task.isCancelled,
              result.count == requests.count else { return nil }
        return result
    }
    deinit { work?.cancel(); dispatchCancellation?.cancel() }
}
