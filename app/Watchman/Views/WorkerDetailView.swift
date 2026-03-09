import SwiftUI

// MARK: - Color Helpers

private func tempColor(_ temp: Int) -> Color {
    if temp >= 85 { return .red }
    if temp >= 75 { return .orange }
    if temp >= 60 { return .yellow }
    return .secondary
}

private func vramColor(_ fraction: Double) -> Color {
    if fraction >= 0.9 { return .red }
    if fraction >= 0.7 { return .yellow }
    return .green
}

// MARK: - GpuGauge

private struct GpuGauge: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(min(percent, 100)) / 100.0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(percent)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
            }
        }
        .frame(width: 44, height: 44)
    }
}

// MARK: - CompactBar

private struct CompactBar: View {
    let fraction: Double
    var height: CGFloat = 6
    var tint: Color = .blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint.opacity(0.15))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(CGFloat(fraction), 0), 1))
            }
        }
        .frame(height: height)
    }
}

// MARK: - SecondaryMetricRow

private struct SecondaryMetricRow: View {
    let icon: String
    let label: String
    let fraction: Double
    let valueText: String
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .frame(width: 28, alignment: .leading)
            CompactBar(fraction: fraction, height: 5, tint: tint)
            Text(valueText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 8) {
            // Header: badge + name + staleness
            HStack(spacing: 6) {
                if let idx = worker.index {
                    Text("\(idx)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(worker.state == .unreachable ? .gray : badgeColor(idx))
                        )
                }
                Text(displayAlias)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if worker.state == .unreachable {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                }
                if let staleness = worker.staleness {
                    Text(staleness)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let m = worker.metrics {
                // GPU section — highlighted green card
                if let gpu = m.gpu {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            GpuGauge(percent: Int(gpu.usage_percent))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("GPU")
                                        .font(.caption.bold())
                                    Text("\(gpu.usage_percent)%")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text("VRAM")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    CompactBar(
                                        fraction: gpu.vramFraction,
                                        height: 5,
                                        tint: vramColor(gpu.vramFraction)
                                    )
                                    Text("\(gpu.vramUsedFormatted)/\(gpu.vramTotalFormatted)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 12) {
                                    Label("\(gpu.temp_c)°C", systemImage: "thermometer")
                                        .font(.caption2)
                                        .foregroundStyle(tempColor(Int(gpu.temp_c)))
                                    Label("\(gpu.fan_speed_percent)%", systemImage: "fan")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green.opacity(0.06))
                    )
                } else {
                    HStack {
                        Image(systemName: "gpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("GPU")
                            .font(.caption)
                        Text("N/A")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Secondary metrics
                SecondaryMetricRow(
                    icon: "cpu",
                    label: "CPU",
                    fraction: Double(m.cpu.usage_percent) / 100.0,
                    valueText: String(format: "%.0f%%", m.cpu.usage_percent),
                    tint: .blue
                )

                SecondaryMetricRow(
                    icon: "memorychip",
                    label: "RAM",
                    fraction: m.memory.fraction,
                    valueText: "\(m.memory.usedFormatted)/\(m.memory.totalFormatted)",
                    tint: .orange
                )

                SecondaryMetricRow(
                    icon: "internaldrive",
                    label: "Disk",
                    fraction: m.disk.fraction,
                    valueText: "\(m.disk.usedFormatted)/\(m.disk.totalFormatted)",
                    tint: .purple
                )

                // CPU temperature
                if let cpuTemp = m.temps.cpu_temp_c {
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(String(format: "CPU %.0f°C", cpuTemp))
                            .font(.caption2)
                            .foregroundStyle(tempColor(Int(cpuTemp)))
                    }
                    .padding(.leading, 1)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .opacity(worker.state == .unreachable ? 0.6 : 1.0)
    }

    private func badgeColor(_ index: Int) -> Color {
        [Color.blue, .purple, .teal, .indigo][index % 4]
    }
}
