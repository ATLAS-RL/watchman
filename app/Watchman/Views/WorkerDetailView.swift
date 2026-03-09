import SwiftUI

// MARK: - Cobalt Next Dark Accent Colors

private let cobaltGreen = Color(red: 0x99/255.0, green: 0xC7/255.0, blue: 0x95/255.0)   // #99C795
private let cobaltYellow = Color(red: 0xFA/255.0, green: 0xC8/255.0, blue: 0x63/255.0)  // #FAC863
private let cobaltRed = Color(red: 0xE6/255.0, green: 0x57/255.0, blue: 0x7A/255.0)     // #E6577A
private let cobaltOrange = Color(red: 0xD6/255.0, green: 0x83/255.0, blue: 0x8C/255.0)  // #D6838C

// MARK: - Color Helpers

private func usageColor(_ percent: Int) -> Color {
    if percent >= 85 { return cobaltRed }
    if percent >= 70 { return cobaltYellow }
    return cobaltGreen
}

private func tempColor(_ temp: Int) -> Color {
    if temp >= 85 { return cobaltRed }
    if temp >= 75 { return cobaltOrange }
    if temp >= 60 { return cobaltYellow }
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
