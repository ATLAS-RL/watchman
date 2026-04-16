import Charts
import SwiftUI

// MARK: - View model

@MainActor
final class PowerHistoryViewModel: ObservableObject {
    @Published var buckets: [PowerAggregate] = []
    @Published var summary: PowerSummary = .empty
    @Published var window: PowerWindow = .day {
        didSet { Task { await reload() } }
    }
    @Published var selectedHost: String? = nil {
        didSet { Task { await reload() } }
    }
    @Published var isLoading = false

    private var refreshTimer: Timer?

    func start() {
        Task { await reload() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func reload() async {
        isLoading = true
        let host = selectedHost
        let win = window
        async let aggTask = PowerStore.shared.aggregate(hostname: host, window: win)
        async let sumTask = PowerStore.shared.summary(hostname: host, window: win)
        let (agg, sum) = await (aggTask, sumTask)
        buckets = agg
        summary = sum
        isLoading = false
    }
}

// MARK: - Window scene host

struct PowerHistoryWindow: View {
    @ObservedObject var poller: MetricsPoller
    @StateObject private var vm = PowerHistoryViewModel()

    var body: some View {
        PowerHistoryView(vm: vm, hosts: hostnames)
            .onAppear { vm.start() }
            .onDisappear { vm.stop() }
            .frame(minWidth: 640, minHeight: 440)
            .background(Theme.panelBg)
            .preferredColorScheme(.dark)
    }

    private var hostnames: [String] {
        poller.workers.compactMap { $0.metrics?.hostname }
    }
}

// MARK: - Main view

struct PowerHistoryView: View {
    @ObservedObject var vm: PowerHistoryViewModel
    let hosts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summaryCards
            chart
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Power History")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Picker("Worker", selection: $vm.selectedHost) {
                Text("All").tag(String?.none)
                ForEach(hosts, id: \.self) { h in
                    Text(h).tag(String?.some(h))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            Picker("Window", selection: $vm.window) {
                ForEach(PowerWindow.allCases) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            SummaryCard(
                title: "Total",
                primary: String(format: "%.3f kWh", vm.summary.totalKwh),
                secondary: vm.window.label
            )
            SummaryCard(
                title: "Mean",
                primary: String(format: "%.0f W", vm.summary.meanW),
                secondary: "avg instantaneous"
            )
            SummaryCard(
                title: "Peak",
                primary: String(format: "%.0f W", vm.summary.peakW),
                secondary: "max instantaneous"
            )
            SummaryCard(
                title: "Min",
                primary: String(format: "%.0f W", vm.summary.minW),
                secondary: "idle floor"
            )
            IdleActiveCard(
                idleKwh: vm.summary.idleKwh,
                activeKwh: vm.summary.activeKwh
            )
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instantaneous CPU + GPU power")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Group {
                if vm.buckets.isEmpty {
                    emptyState
                } else {
                    Chart {
                        ForEach(vm.buckets) { b in
                            LineMark(
                                x: .value("time", b.bucketStart),
                                y: .value("watts", b.meanCpuW)
                            )
                            .foregroundStyle(by: .value("series", "CPU"))
                            LineMark(
                                x: .value("time", b.bucketStart),
                                y: .value("watts", b.meanGpuW)
                            )
                            .foregroundStyle(by: .value("series", "GPU"))
                        }
                    }
                    .chartForegroundStyleScale([
                        "CPU": Color(red: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0),
                        "GPU": Color(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0),
                    ])
                    .chartYAxisLabel("W")
                }
            }
            .frame(minHeight: 180)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Text("No samples in this window")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 12, design: .monospaced))
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Cards

private struct SummaryCard: View {
    let title: String
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Text(primary)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(secondary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
    }
}

private struct IdleActiveCard: View {
    let idleKwh: Double
    let activeKwh: Double

    private var total: Double { max(idleKwh + activeKwh, 0.0001) }
    private var idleFraction: Double { idleKwh / total }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Idle / Active")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x44/255.0))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color(red: 0x4A/255.0, green: 0x4A/255.0, blue: 0x5C/255.0))
                            .frame(width: geo.size.width * idleFraction)
                        Rectangle()
                            .fill(Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                Text(String(format: "idle %.3f", idleKwh))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text(String(format: "active %.3f", activeKwh))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
    }
}
