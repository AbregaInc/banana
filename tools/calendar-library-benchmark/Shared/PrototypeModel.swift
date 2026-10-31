import Foundation

@MainActor
final class PrototypeModel {
    let store: FixtureStore
    let cache = GeometryCache()
    let optimizations = Optimizations()
    private(set) var date: Date
    private(set) var layouts: [DayGeometry] = []
    private(set) var geometryBuilds = 0
    private(set) var prefetchBuilds = 0
    private var generation = 0
    private var prefetch: Task<[DayGeometry], Never>?
    var dayCount: Int { store.config.mode == "week" ? 5 : 1 }
    init(store: FixtureStore) { self.store = store; date = store.anchor }
    func resolve(to date: Date) -> [DayGeometry] {
        let start = store.calendar.startOfDay(for: date)
        return (0..<dayCount).map { offset in
            let day = store.calendar.date(byAdding: .day, value: offset, to: start)!
            if optimizations.cached, let cached = cache.get(day) { return cached }
            let geometry = DayGeometry(date: day, calendar: store.calendar, events: store.day(day), useHeap: optimizations.heap, buildIndex: optimizations.indexed)
            geometryBuilds += 1; cache.put(geometry); return geometry
        }
    }
    func move(to date: Date, prepared: [DayGeometry]? = nil) {
        generation += 1; prefetch?.cancel()
        self.date = store.calendar.startOfDay(for: date)
        if let prepared {
            precondition(prepared.count == dayCount && prepared.first?.date == self.date)
            layouts = prepared
            for day in prepared { cache.put(day) }
        } else { layouts = resolve(to: self.date) }
    }
    func preloadAdjacent() {
        guard optimizations.preload && optimizations.cached else { return }
        let token = generation
        let calendar = store.calendar
        let dates = Array(-dayCount..<0) + Array(dayCount..<(dayCount * 2))
        let inputs = dates.compactMap { offset -> (Date, [Fixture])? in
            let day = calendar.date(byAdding: .day, value: offset, to: date)!
            guard cache.get(day) == nil else { return nil }
            return (day, store.day(day))
        }
        guard !inputs.isEmpty else { return }
        let useHeap = optimizations.heap
        let buildIndex = optimizations.indexed
        let work = Task.detached(priority: .utility) {
            var layouts: [DayGeometry] = []
            for (day, events) in inputs {
                guard !Task.isCancelled else { break }
                layouts.append(DayGeometry(date: day, calendar: calendar, events: events, useHeap: useHeap, buildIndex: buildIndex))
            }
            return layouts
        }
        prefetch = work
        Task { [weak self] in
            let prepared = await work.value
            guard let self, self.generation == token, !work.isCancelled else { return }
            for geometry in prepared { self.cache.put(geometry) }
            self.prefetchBuilds += prepared.count
        }
    }
    func memoryPressure() {
        generation += 1; prefetch?.cancel(); cache.clear()
    }
    deinit { prefetch?.cancel() }
}
