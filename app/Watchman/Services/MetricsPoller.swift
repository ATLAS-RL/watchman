import Foundation
import SwiftUI

@MainActor
class MetricsPoller: ObservableObject {
    @Published var workers: [WorkerEntry] = []
    @Published var lastPollTime: Date?

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
                    ingestSample(metrics)
                } else {
                    workers[index].markUnreachable()
                }
            }
            lastPollTime = Date()
        }
    }

    private func ingestSample(_ m: WorkerMetrics) {
        let sample = MetricSample(
            timestamp: Date(),
            hostname: m.hostname,
            cpuW: m.power?.cpu_w.map(Double.init) ?? nil,
            gpuW: m.power?.gpu_w.map(Double.init) ?? nil,
            cpuUsagePct: Double(m.cpu.usage_percent),
            gpuUsagePct: Double(m.gpu?.usage_percent ?? 0),
            gpuTempC: m.gpu.map { Double($0.temp_c) },
            cpuTempC: m.temps.cpu_temp_c.map(Double.init),
            vramUsedMb: m.gpu?.vram_used_mb,
            vramTotalMb: m.gpu?.vram_total_mb,
            memUsedMb: m.memory.used_mb,
            memTotalMb: m.memory.total_mb,
            diskUsedGb: m.disk.used_gb,
            diskTotalGb: m.disk.total_gb
        )
        Task { await MetricStore.shared.ingest(sample) }
    }

    deinit {
        timer?.invalidate()
    }
}
