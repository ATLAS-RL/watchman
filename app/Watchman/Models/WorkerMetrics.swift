import Foundation

struct WorkerMetrics: Codable, Identifiable {
    var id: String { hostname }

    let hostname: String
    let cpu: CpuMetrics
    let gpu: GpuMetrics?
    let memory: MemoryMetrics
    let disk: DiskMetrics
    let temps: TempMetrics
    let timestamp: String

    struct CpuMetrics: Codable {
        let usage_percent: Float
        let core_count: Int
        let per_core: [Float]
    }

    struct GpuMetrics: Codable {
        let usage_percent: UInt32
        let vram_used_mb: UInt64
        let vram_total_mb: UInt64
        let temp_c: UInt32
        let fan_speed_percent: UInt32
    }

    struct MemoryMetrics: Codable {
        let used_mb: UInt64
        let total_mb: UInt64
    }

    struct DiskMetrics: Codable {
        let used_gb: UInt64
        let total_gb: UInt64
    }

    struct TempMetrics: Codable {
        let cpu_temp_c: Float?
    }
}

enum WorkerState {
    case ok
    case warning
    case critical
    case unreachable

    var color: String {
        switch self {
        case .ok: return "green"
        case .warning: return "yellow"
        case .critical: return "red"
        case .unreachable: return "gray"
        }
    }

    var systemColor: SwiftUI.Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unreachable: return .gray
        }
    }
}

import SwiftUI

struct WorkerEntry: Identifiable {
    let id: String
    let url: URL
    var metrics: WorkerMetrics?
    var state: WorkerState = .unreachable

    var displayName: String {
        metrics?.hostname ?? id
    }

    mutating func update(with metrics: WorkerMetrics) {
        self.metrics = metrics
        self.state = Self.evaluateState(metrics)
    }

    mutating func markUnreachable() {
        self.metrics = nil
        self.state = .unreachable
    }

    private static func evaluateState(_ m: WorkerMetrics) -> WorkerState {
        if let gpu = m.gpu {
            if gpu.temp_c > 85 { return .critical }
            if gpu.temp_c > 75 { return .warning }
        }
        let ramPercent = m.memory.total_mb > 0
            ? Double(m.memory.used_mb) / Double(m.memory.total_mb)
            : 0
        if ramPercent > 0.90 { return .warning }
        return .ok
    }
}

enum OverallStatus {
    case allGood
    case someWarning
    case someCritical
    case allUnreachable

    var label: String {
        switch self {
        case .allGood: return "OK"
        case .someWarning: return "WARN"
        case .someCritical: return "CRIT"
        case .allUnreachable: return "OFF"
        }
    }
}
