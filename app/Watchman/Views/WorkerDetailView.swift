import SwiftUI

// MARK: - Dracula Accent Colors

private let draculaGreen = Color(red: 0x50/255.0, green: 0xFA/255.0, blue: 0x7B/255.0)   // #50FA7B
private let draculaYellow = Color(red: 0xF1/255.0, green: 0xFA/255.0, blue: 0x8C/255.0)  // #F1FA8C
private let draculaRed = Color(red: 0xFF/255.0, green: 0x55/255.0, blue: 0x55/255.0)     // #FF5555
private let draculaOrange = Color(red: 0xFF/255.0, green: 0xB8/255.0, blue: 0x6C/255.0)  // #FFB86C

// MARK: - Color Helpers

private func usageColor(_ percent: Int) -> Color {
    if percent >= 85 { return draculaRed }
    if percent >= 70 { return draculaYellow }
    return draculaGreen
}

private func tempColor(_ temp: Int) -> Color {
    if temp >= 85 { return draculaRed }
    if temp >= 75 { return draculaOrange }
    if temp >= 60 { return draculaYellow }
    return Theme.textSecondary
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
                // CPU block (usage + temp bar, then RAM capacity)
                MetricRow(
                    label: "CPU",
                    percent: Int(m.cpu.usage_percent),
                    temp: m.temps.cpu_temp_c.map { Int($0) }
                )
                CapacityRow(label: "RAM", used: m.memory.usedFormatted, total: m.memory.totalFormatted)

                // GPU block (usage + temp bar, then VRAM capacity) — if present
                if let gpu = m.gpu {
                    MetricRow(label: "GPU", percent: Int(gpu.usage_percent), temp: Int(gpu.temp_c))
                    CapacityRow(label: "VRAM", used: gpu.vramUsedFormatted, total: gpu.vramTotalFormatted)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBg))
        .opacity(worker.state == .unreachable ? 0.5 : 1.0)
    }
}
