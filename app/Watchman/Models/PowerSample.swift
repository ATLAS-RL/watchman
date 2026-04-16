import Foundation

struct PowerSample {
    let timestamp: Date
    let hostname: String
    let cpuW: Double?
    let gpuW: Double?
    let cpuUsagePct: Double
    let gpuUsagePct: Double
}

enum PowerWindow: String, CaseIterable, Identifiable {
    case hour, day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: return "1 hour"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    /// How far back the history query should look for the selected window.
    var lookback: TimeInterval {
        switch self {
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }

    /// SQLite strftime format used to group samples into buckets.
    ///
    /// Hour/Day → per-minute buckets (smooth enough for a chart).
    /// Week     → per-hour.
    /// Month    → per-day.
    var bucketFormat: String {
        switch self {
        case .hour: return "%Y-%m-%d %H:%M"
        case .day:  return "%Y-%m-%d %H:%M"
        case .week: return "%Y-%m-%d %H:00"
        case .month: return "%Y-%m-%d 00:00"
        }
    }
}

struct PowerAggregate: Identifiable {
    let bucketStart: Date
    let energyWh: Double
    let meanCpuW: Double
    let meanGpuW: Double
    let peakW: Double
    let minW: Double
    let idleWh: Double
    let activeWh: Double

    var id: Date { bucketStart }
    var meanTotalW: Double { meanCpuW + meanGpuW }
}

struct PowerSummary {
    let totalKwh: Double
    let meanW: Double
    let peakW: Double
    let minW: Double
    let idleKwh: Double
    let activeKwh: Double

    static let empty = PowerSummary(
        totalKwh: 0, meanW: 0, peakW: 0, minW: 0, idleKwh: 0, activeKwh: 0
    )
}
