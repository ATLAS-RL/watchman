import Foundation
import SwiftUI

@MainActor
class MetricsPoller: ObservableObject {
    @Published var workers: [WorkerEntry] = []

    private var timer: Timer?
    private let session: URLSession

    var overallStatus: OverallStatus {
        let states = workers.map(\.state)
        if states.allSatisfy({ $0 == .unreachable }) { return .allUnreachable }
        if states.contains(where: { $0 == .critical }) { return .someCritical }
        if states.contains(where: { $0 == .warning }) { return .someWarning }
        return .allGood
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: config)

        self.workers = [
            WorkerEntry(
                id: "worker-0",
                url: URL(string: "http://ivantha-worker-0.local:8085/metrics")!
            ),
            WorkerEntry(
                id: "worker-1",
                url: URL(string: "http://ivantha-worker-1.local:8085/metrics")!
            ),
        ]

        startPolling()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.fetchAll()
            }
        }
        // Fire immediately
        Task { await fetchAll() }
    }

    private func fetchAll() async {
        await withTaskGroup(of: (Int, WorkerMetrics?).self) { group in
            for (index, worker) in workers.enumerated() {
                let url = worker.url
                let session = self.session
                group.addTask {
                    do {
                        let (data, _) = try await session.data(from: url)
                        let metrics = try JSONDecoder().decode(WorkerMetrics.self, from: data)
                        return (index, metrics)
                    } catch {
                        return (index, nil)
                    }
                }
            }

            for await (index, metrics) in group {
                if let metrics {
                    workers[index].update(with: metrics)
                } else {
                    workers[index].markUnreachable()
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
