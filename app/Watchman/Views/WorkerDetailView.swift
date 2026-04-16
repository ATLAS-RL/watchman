import SwiftUI

// MARK: - Neon Noir Accent Colors

private let neonGreen = Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0)    // #00FF88
private let neonYellow = Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0)   // #FFE500
private let neonRed = Color(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0)      // #FF0050
private let neonOrange = Color(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0)   // #FF7A00
private let neonGray = Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x44/255.0)     // #333344

// MARK: - Color Helpers

private func usageColor(_ percent: Int) -> Color {
    if percent >= 85 { return neonRed }
    if percent >= 70 { return neonYellow }
    return neonGreen
}

private func tempColor(_ temp: Int) -> Color {
    if temp >= 85 { return neonRed }
    if temp >= 75 { return neonOrange }
    if temp >= 60 { return neonYellow }
    return neonGray
}

// MARK: - MetricRow

private struct MetricRow: View {
    let label: String
    let percent: Int
    var temp: Int? = nil

    private var barColor: Color { usageColor(percent) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text("\(percent)%")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(width: 32, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.trackGray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100.0)
                }
            }
            .frame(height: 6)
            if let temp {
                Text("\(temp)°C")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(temp))
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - CapacityRow

// MARK: - PowerRow

/// Single-line row showing instantaneous watts with a bar scaled against a
/// nominal TDP budget. `watts == nil` renders a muted placeholder.
private struct PowerRow: View {
    let label: String
    let watts: Float?
    let tdpBudget: Double  // watts; bar fills to 100% here

    private var displayPercent: Double {
        guard let w = watts, tdpBudget > 0 else { return 0 }
        return min(max(Double(w) / tdpBudget, 0), 1.2) * 100
    }

    private var barColor: Color {
        let pct = Int(displayPercent)
        if pct >= 95 { return Color(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0) }
        if pct >= 75 { return Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0) }
        return Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            if let w = watts {
                Text(String(format: "%.0f W", w))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                    .frame(width: 48, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.trackGray)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(min(displayPercent, 100)) / 100.0)
                    }
                }
                .frame(height: 6)
            } else {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 48, alignment: .trailing)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - CapacityRow

private struct CapacityRow: View {
    let label: String
    let used: String
    let total: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text("\(used)/\(total)")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - WorkerDetailView

struct WorkerDetailView: View {
    let worker: WorkerEntry
    var alias: String?

    private var displayAlias: String {
        if let alias, !alias.isEmpty { return alias }
        return worker.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: status dot + name
            HStack(spacing: 6) {
                Circle()
                    .fill(worker.state.systemColor)
                    .frame(width: 8, height: 8)
                Text(displayAlias)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                if worker.state == .unreachable {
                    Text("unreachable")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let m = worker.metrics {
                // CPU block (usage + temp bar, RAM capacity, power)
                MetricRow(
                    label: "CPU",
                    percent: Int(m.cpu.usage_percent),
                    temp: m.temps.cpu_temp_c.map { Int($0) }
                )
                CapacityRow(label: "RAM", used: m.memory.usedFormatted, total: m.memory.totalFormatted)
                PowerRow(
                    label: "CPU W",
                    watts: m.power?.cpu_w,
                    tdpBudget: PowerLimits.cpu(for: m.hardware?.cpu_model)
                )

                // GPU block (usage + temp bar, VRAM capacity, power) — if present
                if let gpu = m.gpu {
                    MetricRow(label: "GPU", percent: Int(gpu.usage_percent), temp: Int(gpu.temp_c))
                    CapacityRow(label: "VRAM", used: gpu.vramUsedFormatted, total: gpu.vramTotalFormatted)
                    PowerRow(
                        label: "GPU W",
                        watts: m.power?.gpu_w,
                        tdpBudget: PowerLimits.gpu(for: m.hardware?.gpu_model)
                    )
                } else {
                    HStack(spacing: 6) {
                        Text("GPU")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, alignment: .leading)
                        Text("—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
        .opacity(worker.state == .unreachable ? 0.5 : 1.0)
    }
}
