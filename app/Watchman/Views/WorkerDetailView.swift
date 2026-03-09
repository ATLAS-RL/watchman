import SwiftUI

struct WorkerDetailView: View {
    let worker: WorkerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Circle()
                    .fill(worker.state.systemColor)
                    .frame(width: 8, height: 8)
                Text(worker.displayName)
                    .font(.headline)
                Spacer()
                if worker.state == .unreachable {
                    Text("Unreachable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let m = worker.metrics {
                // CPU
                MetricRow(
                    label: "CPU",
                    value: String(format: "%.0f%%", m.cpu.usage_percent),
                    progress: Double(m.cpu.usage_percent) / 100.0,
                    tint: .blue
                )

                // GPU
                if let gpu = m.gpu {
                    MetricRow(
                        label: "GPU",
                        value: "\(gpu.usage_percent)%",
                        progress: Double(gpu.usage_percent) / 100.0,
                        tint: .green
                    )
                    MetricRow(
                        label: "VRAM",
                        value: "\(gpu.vram_used_mb)MB / \(gpu.vram_total_mb)MB",
                        progress: gpu.vram_total_mb > 0
                            ? Double(gpu.vram_used_mb) / Double(gpu.vram_total_mb)
                            : 0,
                        tint: .green
                    )
                } else {
                    HStack {
                        Text("GPU")
                            .font(.caption)
                            .frame(width: 40, alignment: .leading)
                        Text("N/A")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // RAM
                let ramPercent = m.memory.total_mb > 0
                    ? Double(m.memory.used_mb) / Double(m.memory.total_mb)
                    : 0
                MetricRow(
                    label: "RAM",
                    value: "\(m.memory.used_mb)MB / \(m.memory.total_mb)MB",
                    progress: ramPercent,
                    tint: .orange
                )

                // Disk
                let diskPercent = m.disk.total_gb > 0
                    ? Double(m.disk.used_gb) / Double(m.disk.total_gb)
                    : 0
                MetricRow(
                    label: "Disk",
                    value: "\(m.disk.used_gb)GB / \(m.disk.total_gb)GB",
                    progress: diskPercent,
                    tint: .purple
                )

                // Temps & Fan
                HStack(spacing: 16) {
                    if let cpuTemp = m.temps.cpu_temp_c {
                        Label(String(format: "CPU %.0f°C", cpuTemp), systemImage: "thermometer")
                            .font(.caption)
                    }
                    if let gpu = m.gpu {
                        Label("\(gpu.temp_c)°C", systemImage: "thermometer.sun")
                            .font(.caption)
                        Label("\(gpu.fan_speed_percent)%", systemImage: "fan")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .frame(width: 40, alignment: .leading)
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(tint)
                Text(value)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .trailing)
            }
        }
    }
}
